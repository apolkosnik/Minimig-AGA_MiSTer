; t_trirq_pipe.s - plan M9.T step 4: a TRACE and an INTERRUPT pending at the
; same instruction boundary.  Runs under tb_ap040_pipe_compat.v.
; Protocol: $F100 word = failing check, $F102 = $600D / $BAD0.
;
; M68040UM 8.3, Table 8-4: Trace is exception priority group 6 and Interrupt
; is group 8, "with 0 as the highest priority", so the TRACE is processed
; first.  8.3 then says what becomes of the interrupt: "As soon as the M68040
; has completed exception processing for a condition when an interrupt
; exception is pending, it begins exception processing for the interrupt
; exception instead of executing the exception handler for the original
; exception condition."  So the order is: trace frame, then interrupt frame
; whose stacked PC is the TRACE HANDLER's entry, then the interrupt handler
; runs, returns to the trace handler, which returns to the program.
;
; The coincidence is made DETERMINISTIC instead of swept: a level-2 request is
; raised while the mask is 7, and the instruction that lowers the mask is
; itself traced (T1 was already set when it started).  At its boundary both
; exceptions are pending, every time.
;
;   1  exactly one trace and one interrupt, and the interrupt handler ran
;      FIRST -- it sees the trace handler's guard still clear
;   2  the TRACE frame is format $2 / vector 9, its stacked PC is the
;      instruction after the MOVE to SR and its address field is the MOVE
;   3  the INTERRUPT frame is format $0 / vector 26 and its stacked PC is
;      the trace handler's entry address
;   4  the SR the interrupt stacked is the one trace entry produced: S set,
;      T bits CLEAR, and the mask the MOVE to SR had just written
;   5  ... and the program resumes correctly afterwards, with T still set
;      for the next instruction (the trace handler's RTE restores it)

FAILREG		equ	$F100
DONEREG		equ	$F102
IPLREG		equ	$F110
cnt_trace	equ	$3600
cnt_int		equ	$3604
tr_guard	equ	$3608		; the trace handler's first instruction
tr_pc		equ	$360C		; the trace frame's stacked PC
tr_addr		equ	$3610		; ... and its format-$2 address field
tr_fv		equ	$3614		; ... and its format/vector word
in_pc		equ	$3618		; the interrupt frame's stacked PC
in_fv		equ	$361C		; ... and its format/vector word
in_sr		equ	$3620		; ... and its SR
guard_seen	equ	$3624		; the guard as the interrupt handler saw it
after		equ	$3628		; instructions traced after the pair
in2_pc		equ	$362C		; the T0 leg's interrupt frame: stacked PC
in2_fv		equ	$3630		; ... and its format/vector word
guard2_seen	equ	$3634		; ... and the guard it saw

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
	rept	7
	dc.l	unexp		; 2-8
	endr
	dc.l	h_trace		; 9 trace
	rept	16
	dc.l	unexp		; 10-25
	endr
	dc.l	h_int2		; 26: autovector, level 2
	rept	229
	dc.l	unexp		; 27-255
	endr

	org	$400
start:
	move.w	#$2700,sr
	clr.l	(cnt_trace).l
	clr.l	(cnt_int).l
	clr.l	(tr_guard).l
	clr.l	(guard_seen).l
	clr.l	(guard2_seen).l
	clr.l	(after).l

	move.w	#2,(IPLREG).l		; the request stands, masked out
	moveq	#20,d1
settle:	dbra	d1,settle

	move.w	#$A700,sr		; T1 on, mask still 7: not traced itself
tmov:	move.w	#$A000,sr		; TRACED (T1 was set at its start) and it
					; opens the mask, so at THIS boundary a
					; trace and an interrupt are both pending
tnext:	nop				; traced in its turn (check 5)
	move.w	#$2700,sr		; traced, and then tracing stops
tlast:	nop				; not traced

;------------------------------------- 6: the same coincidence under T0
; The MOVE to SR is a T0 synchronisation point (it is in `t0_special`), so the
; instruction that opens the mask is traced under T0 exactly as it was under
; T1, and the same two exceptions are pending at the same boundary.
	move.w	#$2700,sr
	clr.l	(tr_guard).l
	move.w	#2,(IPLREG).l
	moveq	#20,d1
settle2: dbra	d1,settle2
	move.w	#$6700,sr		; T0 on, mask 7: not traced itself
t0mov:	move.w	#$6000,sr		; traced under T0, and it opens the mask
t0next:	nop				; a NOP is a synchronisation point: traced
	move.w	#$2700,sr		; traced, and then tracing stops
	nop				; not traced

;------------------------------------- the checks
	move.l	(cnt_trace).l,d0
	chkl	d0,6,1			; three per leg: the pair's, the NOP's, the MOVE's
	move.l	(cnt_int).l,d0
	chkl	d0,2,1
	move.l	(guard_seen).l,d0	; 1: the interrupt handler ran FIRST
	chkl	d0,0,1

	move.l	(tr_fv).l,d0		; 2: format $2, vector offset $24
	chkl	d0,$2024,2
	move.l	(tr_pc).l,d0
	chkl	d0,tnext,2
	move.l	(tr_addr).l,d0
	chkl	d0,tmov,2

	move.l	(in_fv).l,d0		; 3: format $0, vector offset $68
	chkl	d0,$0068,3
	move.l	(in_pc).l,d0
	chkl	d0,h_trace,3		; the TRACE HANDLER's entry

	move.l	(in_sr).l,d0		; 4: S set, T clear, the new mask
	chkl	d0,$2000,4

	move.l	(after).l,d0		; 5: tracing resumed after the pair
	chkl	d0,5,5

	move.l	(in2_fv).l,d0		; 6: the T0 leg, same rule
	chkl	d0,$0068,6
	move.l	(in2_pc).l,d0
	chkl	d0,h_trace,6
	move.l	(guard2_seen).l,d0
	chkl	d0,0,6

	move.w	#$600D,(DONEREG).l
halt:	bra.s	halt

;--------------------------------------------------------------- handlers
; The trace handler's FIRST instruction sets the guard, so an interrupt that
; is taken in front of it -- which is what the manual requires -- sees zero.
h_trace:
	move.l	#1,(tr_guard).l
	addq.l	#1,(cnt_trace).l
	move.l	(cnt_trace).l,d0
	cmp.l	#1,d0
	bne.s	ht_later
	moveq	#0,d0			; only the FIRST trace is recorded
	move.w	6(sp),d0
	move.l	d0,(tr_fv).l
	move.l	2(sp),(tr_pc).l
	move.l	8(sp),(tr_addr).l
	bra.s	ht_done
ht_later:
	addq.l	#1,(after).l
ht_done:
	rte

h_int2:
	addq.l	#1,(cnt_int).l
	move.w	#0,(IPLREG).l
	move.l	(cnt_int).l,d1
	cmp.l	#1,d1
	bne.s	hi_second
	move.l	(tr_guard).l,d0		; has the trace handler begun?
	move.l	d0,(guard_seen).l
	moveq	#0,d0
	move.w	6(sp),d0
	move.l	d0,(in_fv).l
	move.l	2(sp),(in_pc).l
	moveq	#0,d0
	move.w	(sp),d0
	move.l	d0,(in_sr).l
	rte
hi_second:
	move.l	(tr_guard).l,d0
	move.l	d0,(guard2_seen).l
	moveq	#0,d0
	move.w	6(sp),d0
	move.l	d0,(in2_fv).l
	move.l	2(sp),(in2_pc).l
	rte

fail_all:
	move.w	d7,(FAILREG).l
	move.w	#$BAD0,(DONEREG).l
h1:	bra.s	h1
; an unexpected vector reports its own vector offset as the failing check
unexp:
	move.w	6(sp),d7
	andi.w	#$0FFF,d7
	move.w	d7,(FAILREG).l
	move.w	#$BAD0,(DONEREG).l
h2:	bra.s	h2
