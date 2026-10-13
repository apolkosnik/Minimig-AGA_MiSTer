; MOVEM access-error RESTART (68060), including a MOVEM which overwrites its
; own memory-indirect pointer before faulting.  All cases run in every bus
; phase.
;
; The 68040 version of this test checked the format $7 frame's CM bit and
; saved effective address: the 040 CONTINUES an interrupted MOVEM from the
; register it faulted on, with the EA it computed the first time.  The
; MC68060 has neither.  Its access error frame is format $4 (SR, PC, FA,
; FSLW; MC68060UM 8.4.4) and its recovery is a RESTART model (8.4.4.1: "This
; instruction is restarted when an RTE is executed ... the read cycles that
; are successful prior to the access error are re-executed since the
; processor uses a restart model for recovery"); the RTE "treats the access
; error frame no differently from other frames" (8.4) -- it reloads SR and
; PC and nothing else.  So every converted case below checks the restart:
;
;   * MOVEM.L D1-D3,([A0]) with [A0] = $6FF8 writes $6FF8, $6FFC, $7000.
;     D1 = $6000 lands on $6FF8 -- the MOVEM overwrites its OWN pointer --
;     and page 7 is invalid, so the third write faults (FSLW W|PF, FA $7000).
;     The restart executes the instruction again from its first word: it
;     re-reads the memory-indirect pointer, which now holds $6000, and
;     writes D1-D3 to $6000-$6008.  This is what the manual's restart model
;     implies (the EA is recomputed from memory as it is at the restart; no
;     part of the first attempt's EA survives in the frame) and it is why
;     8.4.5 lists "a MOVE <ea>,<ea> in which the destination operand writes
;     over the source operand" among the nonrecoverable cases: a handler
;     that wants the original effect must repair the source itself.
;     Cases 0 and 5 let the restart run with the overwritten pointer (the
;     writes land at $6000 / $6010, page 7 is never touched again); the
;     other cases have the handler put the pointer back, which steers the
;     restart to $6FF8 again and the third write to the repaired page 7.
;   * A failed table search makes no ATC entry on the 060 (4.3, WinUAE
;     mmu_fill_atc: "68060 only if valid descriptor was found"), so the
;     handler repairs descriptors WITHOUT a PFLUSH and the restart searches
;     again.  Case 1 returns once without repairing: the restart must fault
;     again (a fresh search), then succeed.
;
; Cases (which):
;   0  plain fault; restart through the overwritten pointer -> $6000-$6008
;   1  handler returns unrepaired once (pointer restored): second PF fault,
;      then repaired: $6FF8-$7000
;   2  the handler takes a nested access error (page 12) before repairing:
;      the outer frame (PC, FA, FSLW) must survive it
;   3  handler restores the pointer and repairs: $6FF8-$7000 (the 040 case
;      "handler edits the stacked EA": on the 060 the restart is steered
;      through memory, not the frame)
;   4  handler restores the pointer, repairs, AND rewrites the frame's FA
;      and FSLW (the 040 case "handler clears CM"): the RTE ignores both,
;      nothing is written near the edited address
;   5  ([16.w,A0],16.l): restart through the overwritten pointer
;      -> [$6FF8] = $6000 + 16 = $6010-$6018
;   6  the memory-indirect POINTER read faults (page 9): FSLW R|PF, FA $9000,
;      no MOVEM write has happened; restart completes $6FF8-$7000
;   7  the handler unmasks a pending level 2 interrupt: it is taken at the
;      instruction boundary after the RTE, BEFORE the restarted MOVEM (the
;      interrupt frame's PC is the MOVEM, $7000 not yet written); its RTE
;      then runs the restart
;   8  MOVEM at $D000 (called by JSR); the handler also invalidates the
;      MOVEM's own code page (needs PFLUSH: that search succeeded, its I-ATC
;      entry stays) so the restart's opword fetch faults: FA $D000, FSLW
;      IO|PF, supervisor program; repaired without PFLUSH, restart completes
FAILREG         equ $F100
DONEREG         equ $F102
which           equ $3600
faults          equ $3602
nested          equ $3604
irqs            equ $3606
mvpc            equ $3608           ; address of this case's MOVEM
FS_WPF          equ $00850200       ; W, long, TM 5 (supervisor data), PF
FS_RPF          equ $01050200       ; R, long, TM 5, PF
FS_IPF          equ $01068200       ; R, TM 6 (supervisor program), IO, PF
FS_ISIZE        equ $00600000       ; SIZE bits: not compared for a fetch

        org     0
        dc.l    $3400,start,h_aerr
        rept    23
        dc.l    unexpected
        endr
        dc.l    h_int2
        rept    229
        dc.l    unexpected
        endr

        org     $400
start:
        move.w  #$2700,sr
        clr.w   (which).l
next_case:
        move.w  #$2700,sr
        moveq   #0,d0
        movec   d0,tc
        pflusha
        clr.w   (faults).l
        clr.w   (nested).l
        clr.w   (irqs).l
        lea     ($4400).l,a0
        moveq   #63,d1
tables:
        move.l  d0,d2
        lsl.l   #8,d2
        lsl.l   #4,d2
        addq.l  #3,d2
        move.l  d2,(a0)+
        addq.l  #1,d0
        dbra    d1,tables
        move.l  #$4203,($4000).l
        move.l  #$4403,($4200).l
        move.l  #$6FF8,($6FF8).l
        clr.l   ($6FFC).l
        move.l  #$BBBBBBBB,($7000).l
        lea     ($6000).l,a0          ; where a restart through the
        moveq   #7,d1                 ; overwritten pointer lands
clr6:   clr.l   (a0)+
        dbra    d1,clr6
        clr.l   ($6100).l
        clr.l   ($6104).l
        clr.l   ($6108).l
        clr.l   ($441C).l             ; page 7 invalid
        clr.l   ($4430).l             ; nested handler's page 12 invalid
        move.w  #$48F0,($D000).l      ; MOVEM.L D1-D3,([A0]); RTS
        move.w  #$000E,($D002).l
        move.w  #$0151,($D004).l
        move.w  #$4E75,($D006).l
        move.l  #mv_local,(mvpc).l
        lea     ($6FF8).l,a0
        cmpi.w  #5,(which).l
        bne.s   not_displaced
        move.l  #mv_disp,(mvpc).l
        lea     ($6FE8).l,a0
        move.l  #$6FE8,($6FF8).l      ; BD=16, OD=16 -> original EA 6FF8
not_displaced:
        cmpi.w  #8,(which).l
        bne.s   not_far
        move.l  #$D000,(mvpc).l
not_far:
        cmpi.w  #6,(which).l
        bne.s   enable
        move.l  #$7003,($441C).l      ; operand writes do not fault this time
        clr.l   ($4424).l             ; fault while reading the EA pointer
        move.l  #$6FF8,($9000).l
        lea     ($9000).l,a0
enable:
        move.l  #$4000,d0
        movec   d0,urp
        movec   d0,srp
        move.l  #$8000,d0
        movec   d0,tc
        pflusha
        move.l  #$6000,d1
        move.l  #$22222222,d2
        move.l  #$33333333,d3
        cmpi.w  #8,(which).l
        bne.s   local_movem
        jsr     ($D000).l             ; handler will invalidate its instruction page
        bra.s   check
local_movem:
        cmpi.w  #5,(which).l
        beq.s   displaced
mv_local:
        movem.l d1-d3,([a0])          ; 48F0 000E 0151
        bra.s   check
displaced:
mv_disp:
        movem.l d1-d3,([16.w,a0],16.l)
check:
        moveq   #0,d0
        movec   d0,tc
        pflusha
        moveq   #1,d0
        cmpi.w  #1,(which).l
        beq.s   twice
        cmpi.w  #8,(which).l
        bne.s   count_ready
twice:
        moveq   #2,d0
count_ready:
        cmp.w   (faults).l,d0
        bne     fail_count
        cmpi.w  #2,(which).l
        bne.s   check_dest
        cmpi.w  #1,(nested).l
        bne     fail_nested
check_dest:
        cmpi.w  #7,(which).l
        bne.s   irq_checked
        cmpi.w  #1,(irqs).l
        bne     fail_irq
irq_checked:
        ; Every case's first attempt (except 6, whose pointer read faulted
        ; before any write) stored D1 over the pointer and D2 after it; the
        ; restarted MOVEM writes them there again when the pointer was
        ; restored.  Either way $6FF8/$6FFC end up D1/D2.
        cmpi.l  #$6000,($6FF8).l
        bne     fail_dest
        cmpi.l  #$22222222,($6FFC).l
        bne     fail_dest
        tst.l   ($6100).l             ; nothing ever goes near $6100
        bne     fail_stray            ; (case 4's edited frame FA)
        tst.l   ($6104).l
        bne     fail_stray
        tst.l   ($6108).l
        bne     fail_stray
        cmpi.w  #0,(which).l
        beq.s   via_6000
        cmpi.w  #5,(which).l
        beq.s   via_6010
        ; pointer restored (or never overwritten): the restart wrote D3 to
        ; the repaired page 7, nothing went to $6000-$601C
        cmpi.l  #$33333333,($7000).l
        bne     fail_dest
        lea     ($6000).l,a0
        moveq   #7,d1
no_stray:
        tst.l   (a0)+
        bne     fail_stray
        dbra    d1,no_stray
        bra     done_case
via_6000:
        ; restart re-read the overwritten pointer: EA = $6000
        cmpi.l  #$6000,($6000).l
        bne     fail_restart
        cmpi.l  #$22222222,($6004).l
        bne     fail_restart
        cmpi.l  #$33333333,($6008).l
        bne     fail_restart
        tst.l   ($600C).l
        bne     fail_stray
        bra     page7_untouched
via_6010:
        ; ([16,A0],16) restarted: [$6FF8] = $6000, + od 16 = $6010
        tst.l   ($600C).l
        bne     fail_stray
        cmpi.l  #$6000,($6010).l
        bne     fail_restart
        cmpi.l  #$22222222,($6014).l
        bne     fail_restart
        cmpi.l  #$33333333,($6018).l
        bne     fail_restart
        tst.l   ($601C).l
        bne     fail_stray
page7_untouched:
        cmpi.l  #$BBBBBBBB,($7000).l  ; the first attempt faulted there,
        bne     fail_dest             ; the restart went elsewhere
done_case:
        addq.w  #1,(which).l
        cmpi.w  #9,(which).l
        bne     next_case
        move.w  #$600D,(DONEREG).l
        stop    #$2700

; Access error.  Frame at 8(sp) (after the 8-byte save): +8 SR, +10 PC,
; +14 $4008, +16 fault address, +20 FSLW.
h_aerr:
        movem.l d0/a1,-(sp)          ; frame offsets below include 8-byte save
        cmpi.w  #$4008,14(sp)
        bne     unexpected
        cmpi.l  #$C000,16(sp)
        beq     inner
        addq.w  #1,(faults).l
        cmpi.w  #2,(faults).l
        bhi     fail_count           ; bounded even if restart loops
        move.l  (mvpc).l,d0
        cmp.l   10(sp),d0            ; PC: the MOVEM, to be restarted
        bne     fail_pc
        cmpi.w  #6,(which).l
        beq     pointer_fault
        cmpi.w  #8,(which).l
        bne.s   operand_fault
        cmpi.w  #2,(faults).l
        bne.s   operand_fault
        ; case 8, second fault: the restart's opword fetch.  FA is the
        ; opword (8.4.4.2), FSLW IO=1 MA=0 (opword), read, supervisor
        ; program space, PF.  SIZE is left out: the 060 fetches the
        ; instruction stream in long words while WinUAE reports the word
        ; it was reading; neither is what this case is about.
        cmpi.l  #$D000,16(sp)
        bne     fail_fa
        move.l  20(sp),d0
        andi.l  #~FS_ISIZE,d0
        cmp.l   #FS_IPF,d0
        bne     fail_fslw
        move.l  #$D003,($4434).l      ; no PFLUSH: no entry was made
        bra     return
operand_fault:
        cmpi.l  #$7000,16(sp)        ; the third write's own address
        bne     fail_fa
        cmp.l   #FS_WPF,20(sp)       ; write, long, supervisor data, PF
        bne     fail_fslw
        cmpi.l  #$6000,($6FF8).l     ; the first write reached memory: the
        bne     fail_dest            ; pointer is overwritten
        cmpi.w  #0,(which).l
        beq.s   repair               ; restart through the new pointer
        cmpi.w  #5,(which).l
        beq.s   repair
        move.l  #$6FF8,($6FF8).l     ; restore the pointer: restart -> $6FF8
        cmpi.w  #1,(which).l
        bne.s   repair
        cmpi.w  #1,(faults).l
        beq     return               ; unrepaired: the restart must search
repair:                              ; again and fault again
        move.l  #$7003,($441C).l     ; no PFLUSH: the failed search left no
        cmpi.w  #8,(which).l         ; ATC entry
        bne.s   arm_irq
        clr.l   ($4434).l             ; fault fetching the restarted instruction:
        pflusha                       ; page 13's successful entry must go
arm_irq:
        cmpi.w  #7,(which).l
        bne.s   nest_check
        andi.w  #$F8FF,8(sp)          ; returning SR unmasks level 2
        move.w  #2,($F110).l
nest_check:
        cmpi.w  #2,(which).l
        bne.s   edit_frame
        move.l  ($C000).l,d0          ; nested access error must not lose
        cmpi.l  #$7000,16(sp)         ; the outer frame
        bne     fail_nested
        cmp.l   #FS_WPF,20(sp)
        bne     fail_nested
        move.l  (mvpc).l,d0
        cmp.l   10(sp),d0
        bne     fail_nested
        cmpi.w  #$4008,14(sp)
        bne     fail_nested
edit_frame:
        cmpi.w  #4,(which).l
        bne.s   return
        move.l  #$6100,16(sp)         ; FA and FSLW are not used by the RTE
        move.l  #$01050008,20(sp)     ; (8.4: no different from other frames)
        bra.s   return
pointer_fault:
        cmpi.l  #$9000,16(sp)
        bne     fail_fa
        cmp.l   #FS_RPF,20(sp)        ; the EA fetch is a read, not a write
        bne     fail_fslw
        cmpi.l  #$6FF8,($6FF8).l      ; no MOVEM write happened yet
        bne     fail_dest
        move.l  #$9003,($4424).l      ; no PFLUSH
return:
        movem.l (sp)+,d0/a1
        rte
inner:
        cmp.l   #FS_RPF,20(sp)
        bne     fail_fslw
        addq.w  #1,(nested).l
        cmpi.w  #1,(nested).l
        bne     fail_nested
        move.l  #$C003,($4430).l      ; no PFLUSH
        bra.s   return

h_int2:
        ; Taken at the boundary between the access error's RTE and the
        ; restarted MOVEM: the 060 has no partially executed instruction to
        ; resume, so the interrupt frame's PC is the MOVEM itself and the
        ; restart has not written $7000 yet.  Its RTE runs the restart.
        cmpi.l  #$BBBBBBBB,($7000).l
        bne     fail_irq
        cmpi.l  #mv_local,2(sp)
        bne     fail_irq
        addq.w  #1,(irqs).l
        clr.w   ($F110).l
        rte

fail_count:     moveq #1,d7
                bra.s fail
fail_nested:    moveq #2,d7
                bra.s fail
fail_dest:      moveq #3,d7
                bra.s fail
fail_stray:     moveq #4,d7
                bra.s fail
fail_pc:        moveq #5,d7
                bra.s fail
fail_fslw:      moveq #6,d7
                bra.s fail
fail_fa:        moveq #7,d7
                bra.s fail
fail_irq:       moveq #8,d7
                bra.s fail
fail_restart:   moveq #9,d7
                bra.s fail
unexpected:    moveq #15,d7
fail:
        move.w  d7,(FAILREG).l
        move.w  #$BAD0,(DONEREG).l
halt:   bra.s   halt
