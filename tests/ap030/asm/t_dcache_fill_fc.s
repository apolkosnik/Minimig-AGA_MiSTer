; AP030 data-cache fill function code after early operand completion.
; MMU function-code lookup maps logical $1100 to different cacheable ROM
; pages for supervisor data (FC=5) and user data (FC=1). The wrapper bench
; aliases these ROM pages to chip RAM, where the initial values are seeded.
; A supervisor word read leaves its 16-bit-port cache fill outstanding when
; MOVES issues the user read. The old fill must keep FC=5, so the user read
; misses and obtains data from its own physical mapping.
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
	move.l	#$11113333,$3100
	move.l	#$22224444,$4100
	move.l	#$7FFF0002,$3000	; CRP: function-code table at $4000
	move.l	#$00004000,$3004
	move.l	#$81C8C000,$3008	; TC: FCL, 4 KB pages, 24-bit logical addresses
	move.l	#$00007002,$4004	; user-data page table
	move.l	#$00005002,$4014	; supervisor-data page table
	move.l	#$00006002,$4018	; supervisor-program page table
	move.l	#$00000019,$5000
	move.l	#$00F83019,$5004	; supervisor $1100 -> ROM $F83100
	move.l	#$00003019,$500C	; stack and MMU configuration
	move.l	#$0000F019,$503C	; bench result ports
	move.l	#$00000019,$6000	; code stays in physical page zero
	move.l	#$00003019,$600C
	move.l	#$0000F019,$603C
	move.l	#$00F84019,$7004	; user $1100 -> ROM $F84100
	moveq	#1,d0
	movec	d0,sfc
	lea	$1100,a0
	pmove	$3000,crp
	pmove	$3008,tc
	move.l	#$900,d0		; clear and enable after changing the mapping
	movec	d0,cacr
	; Keep these adjacent: NOP would drain the fill and hide the race.
	move.w	(a0),d0
	moves.l	(a0),d1
	and.l	#$FFFF,d0
	chkl	d0,$1111,1
	chkl	d1,$22224444,2
	move.w	#$600D,DONEREG
	stop	#$2700

fail_all:
	move.w	d7,FAILREG
	move.w	#$BAD0,DONEREG
	stop	#$2700
unexp:
	move.w	#$FF,d7
	bra	fail_all
