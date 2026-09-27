; Pipelined AP68040, plan M9 subset (pulled forward for gate 1): the
; interrupt, STOP and RESET cases t_exceptions.s does not tell apart.
; Runs under tb_ap040_pipe_compat.v, all three bus phases.
; Protocol: $F100 word = failing check, $F102 = $600D / $BAD0.
;
;   1-18  every level 1..6: autovector 24+L (M68040UM 8.1.4, Table 8-1),
;         the handler runs with mask L, the stacked PC is the instruction
;         the interrupt was taken in front of, the stacked SR the old one
;   19-22 STOP #$2300 with level 2 requesting: not taken; the lines then
;         rise to level 5 ($F150): taken, stacked PC = the instruction after
;         the STOP, stacked SR = the STOP's
;   23-24 STOP #$2700 woken by an NMI (level 7 pierces mask 7), vector 31
;   (1-18: 1-6 wrong level, 7-12 wrong mask, 13-18 wrong PC; 30 stacked SR;
;    31 frame vector word)
;   25-27 RESET: RSTO asserted once for >= 512 clocks (M68040UM 5.7.3 /
;         the RESET instruction: 512 BCLK), execution continues after it
;   28-29 RESET in user mode: privilege violation (vector 8), no RSTO
;   34-38 a swept request against STOP: the stacked SR is always the SR the
;         STOP loaded and the stacked PC the instruction after it (the SR
;         micro-op commits before the interrupt is taken)
;   36-39 a swept request against a run of flag-setting instructions: the
;         stacked CCR is the one the instruction in front of the boundary
;         left (nothing older is still in flight when the frame is built)
;   32-33 an interrupt never lands between an instruction's operand read
;         and its execution: a run of reads of a counting register ($F180,
;         every read counts at $F182) under a swept level-2 request ($F148);
;         the count must equal the reads the program executed (a second
;         read after the RTE would lose a read-to-clear flag, e.g. a CIA ICR)

FAILREG		equ	$F100
DONEREG		equ	$F102
IPLREG		equ	$F110
IPLSTEP		equ	$F150
RSTOLEN		equ	$F170
RSTONUM		equ	$F172
IPLDLY		equ	$F148
RDCNT		equ	$F180
RDCNTN		equ	$F182
logp		equ	$3600		; log pointer
cnt_prv		equ	$3604
cnt_irq		equ	$360C
cnt_ccr		equ	$3610
mode		equ	$3614		; handler check mode: 0 none, 1 STOP sweep, 2 CCR
logbuf		equ	$3700		; per interrupt: level.w, sr.w, pc.l, frame sr.w, vec.w

failt	macro
	move.w	#\1,d7
	bra	fail_all
	endm
chkl	macro
	cmp.l	#\2,\1
	beq.s	ok\@
	failt	\3
ok\@:
	endm

	org	0
	dc.l	$3400
	dc.l	start
	rept	6
	dc.l	unexp		; 2-7
	endr
	dc.l	h_priv		; 8
	rept	15
	dc.l	unexp		; 9-23
	endr
	dc.l	unexp		; 24 spurious (never: autovectors)
	dc.l	h_l1,h_l2,h_l3,h_l4,h_l5,h_l6,h_l7	; 25-31
	rept	224
	dc.l	unexp
	endr

	org	$400
start:
	move.w	#$2700,sr
	move.l	#logbuf,(logp).l
	clr.w	(cnt_prv).l

;------------------------------------------------------ levels 1..6
	moveq	#1,d2			; level
lvl_loop:
	move.w	#$2700,sr
	move.w	d2,(IPLREG).l		; assert under mask 7, let it settle
	move.w	#20,d1
lvl_settle:
	dbra	d1,lvl_settle
	move.w	#$2000,sr		; taken at the next boundary
lvl_here:
	nop
	addq.w	#1,d2
	cmp.w	#7,d2
	bne.s	lvl_loop
	; check the six log entries
	lea	(logbuf).l,a0
	moveq	#1,d2
	moveq	#1,d7			; check number base
chk_loop:
	moveq	#0,d0
	move.w	(a0)+,d0		; level the handler saw (its vector)
	cmp.l	d2,d0
	bne	fail_lvl
	moveq	#0,d0
	move.w	(a0)+,d0		; SR inside the handler
	and.w	#$0700,d0
	move.l	d2,d3
	lsl.l	#8,d3
	cmp.l	d3,d0
	bne	fail_mask
	move.l	(a0)+,d0		; stacked PC
	cmp.l	#lvl_here,d0
	bne	fail_pc
	moveq	#0,d0
	move.w	(a0)+,d0		; stacked SR: mask 0 (the MOVE to SR's)
	cmp.l	#$2000,d0
	bne	fail_fsr
	moveq	#0,d0
	move.w	(a0)+,d0		; frame format/vector word
	move.l	d2,d3
	add.l	#24,d3
	lsl.l	#2,d3			; format 0, offset (24+L)*4
	cmp.l	d3,d0
	bne	fail_vec
	addq.w	#1,d2
	cmp.w	#7,d2
	bne.s	chk_loop

;------------------------------------------------------ STOP and the mask
	move.l	#logbuf,(logp).l
	move.w	#$2700,sr
	move.w	#$4052,(IPLSTEP).l	; level 2 now, level 5 after $40 clocks
	stop	#$2300			; mask 3: level 2 cannot end it, level 5 does
stop_ret:
	move.w	sr,d0
	and.l	#$FFFF,d0
	chkl	d0,$2300,19		; back with the STOP's SR
	lea	(logbuf).l,a0
	moveq	#0,d0
	move.w	(a0),d0
	chkl	d0,5,20			; level 5 first (level 2 never taken under mask 3)
	move.l	4(a0),d0
	chkl	d0,stop_ret,21		; stacked PC: the instruction after the STOP
	moveq	#0,d0
	move.w	8(a0),d0
	chkl	d0,$2300,22		; stacked SR: the one STOP loaded
	move.w	#0,(IPLREG).l

;------------------------------------------------------ STOP #$2700 and NMI
	move.l	#logbuf,(logp).l
	move.w	#$FF70,(IPLSTEP).l	; level 7 after 255 clocks (the STOP is in by then)
	stop	#$2700
nmi_ret:
	lea	(logbuf).l,a0
	moveq	#0,d0
	move.w	(a0),d0
	chkl	d0,7,23
	move.l	4(a0),d0
	chkl	d0,nmi_ret,24
	move.w	#0,(IPLREG).l

;------------------------------------------------------ RESET
	moveq	#0,d0
	move.w	(RSTONUM).l,d0
	chkl	d0,0,25
	moveq	#$55,d4
	reset
	moveq	#0,d0
	move.w	(RSTONUM).l,d0
	chkl	d0,1,26			; one RSTO pulse ...
	moveq	#0,d0
	move.w	(RSTOLEN).l,d0
	cmp.l	#512,d0
	bcc.s	rsto_ok
	failt	27			; ... of at least 512 clocks
rsto_ok:
	cmp.l	#$55,d4
	bne	fail_all
	; RESET from user mode: privilege violation, no pulse
	move.l	#priv_back,(uret).l
	move.w	#$0000,sr		; user mode
	reset
priv_back:
	moveq	#0,d0
	move.w	(cnt_prv).l,d0
	chkl	d0,1,28
	moveq	#0,d0
	move.w	(RSTONUM).l,d0
	chkl	d0,1,29

;------------------------------------------------------ interrupt vs operand read
	move.w	#$2700,sr
	clr.w	(RDCNTN).l
	clr.w	(cnt_irq).l
	moveq	#1,d5			; request delay, swept 1..63
rd_loop:
	move.l	#logbuf,(logp).l
	move.w	d5,(IPLDLY).l		; level 2 after d5 clocks
	move.w	#$2000,sr
	rept	16
	move.w	(RDCNT).l,d0
	endr
	move.w	#100,d1			; let a late request in before masking
rd_wait:
	dbra	d1,rd_wait
	move.w	#$2700,sr
	addq.w	#1,d5
	cmp.w	#64,d5
	bne	rd_loop
	moveq	#0,d0
	move.w	(RDCNTN).l,d0
	chkl	d0,63*16,32		; each read went to the bus once
	moveq	#0,d0
	move.w	(cnt_irq).l,d0
	chkl	d0,63,33		; and every request was taken

;------------------------------------------------------ STOP: the SR commits first
	move.w	#$2700,sr
	move.w	#1,(mode).l
	clr.w	(cnt_irq).l
	moveq	#1,d5			; request delay, swept 1..63
st_loop:
	move.w	#$2700,sr		; (the handler's RTE returned with $2000)
	move.w	d5,(IPLDLY).l		; level 2 after d5 clocks: before, during or after the STOP
	stop	#$2000
stop_ret2:
	addq.w	#1,d5
	cmp.w	#64,d5
	bne.s	st_loop
	move.w	#$2700,sr
	moveq	#0,d0
	move.w	(cnt_irq).l,d0
	chkl	d0,63,38		; every request woke the STOP exactly once

;------------------------------------------------------ the stacked CCR is the boundary's
	move.w	#2,(mode).l
	clr.w	(cnt_ccr).l
	moveq	#1,d5
cc_loop:
	move.w	#$2700,sr
	move.w	d5,(IPLDLY).l
	move.w	#$2000,sr
blk2:
	rept	16
	moveq	#0,d2			; Z set: CCR = $04
	addq.l	#1,d2			; Z clear: CCR = $00
	endr
	move.w	#100,d1
cc_wait:
	dbra	d1,cc_wait
	addq.w	#1,d5
	cmp.w	#64,d5
	bne	cc_loop
	move.w	#$2700,sr
	clr.w	(mode).l
	moveq	#0,d0
	move.w	(cnt_ccr).l,d0
	tst.w	d0
	bne.s	cc_ok
	failt	39			; no interrupt landed inside the block: the check would be vacuous
cc_ok:

	move.w	#$600D,(DONEREG).l
halt:	bra.s	halt

;------------------------------------------------------ handlers
h_l1:	move.w	#1,d6
	bra.s	h_com
h_l2:	move.w	#2,d6
	addq.w	#1,(cnt_irq).l
	move.w	(mode).l,d3
	cmp.w	#1,d3
	beq	h_stopchk
	cmp.w	#2,d3
	beq	h_ccrchk
	bra.s	h_com
h_l3:	move.w	#3,d6
	bra.s	h_com
h_l4:	move.w	#4,d6
	bra.s	h_com
h_l5:	move.w	#5,d6
	bra.s	h_com
h_l6:	move.w	#6,d6
	bra.s	h_com
h_l7:	move.w	#7,d6
h_com:
	move.w	#0,(IPLREG).l		; acknowledge the device
	movea.l	(logp).l,a5
	move.w	d6,(a5)+
	move.w	sr,(a5)+
	move.l	2(sp),(a5)+
	move.w	(sp),(a5)+
	move.w	6(sp),(a5)+
	move.l	a5,(logp).l
	rte

; mode 1: the STOP sweep -- the frame must carry the SR the STOP loaded and
; the PC after it, whenever in the STOP's execution the request arrives
h_stopchk:
	move.w	(sp),d3
	cmp.w	#$2000,d3
	beq.s	h_sc1
	move.w	#34,d7
	bra	fail_all
h_sc1:
	move.l	2(sp),d4
	cmp.l	#stop_ret2,d4
	beq	h_com
	move.w	#35,d7
	bra	fail_all
; mode 2: inside blk2, the stacked CCR is what the instruction before the
; stacked PC left ($04 after moveq #0, $00 after addq.l #1)
h_ccrchk:
	move.l	2(sp),d4
	sub.l	#blk2,d4
	cmp.l	#64,d4
	bcc	h_com			; outside the block
	addq.w	#1,(cnt_ccr).l
	move.w	(sp),d3
	and.w	#$001F,d3
	btst	#1,d4
	bne.s	h_cc_addq
	tst.w	d3
	beq	h_com
	move.w	#36,d7
	bra	fail_all
h_cc_addq:
	cmp.w	#4,d3
	beq	h_com
	move.w	#37,d7
	bra	fail_all

uret	equ	$3608
h_priv:	addq.w	#1,(cnt_prv).l
	ori.w	#$2700,(sp)		; return in supervisor mode with interrupts masked ...
	move.l	(uret).l,2(sp)		; ... past the instruction that trapped
	rte

fail_lvl:	add.w	#0,d2
		move.w	d2,d7
		bra.s	fail_all
fail_mask:	move.w	d2,d7
		addq.w	#6,d7
		bra.s	fail_all
fail_pc:	move.w	d2,d7
		add.w	#12,d7
		bra.s	fail_all
fail_fsr:	move.w	#30,d7
		bra.s	fail_all
fail_vec:	move.w	#31,d7
fail_all:
	move.w	d7,(FAILREG).l
	move.w	#$BAD0,(DONEREG).l
h1:	bra.s	h1
unexp:
	move.w	#$0099,(FAILREG).l
	move.w	#$BAD0,(DONEREG).l
h2:	bra.s	h2
