; The AP68060 in Minimig: list stores in Fast RAM against interrupts taken
; at random points between them (tests/ap060/tb_ap060_wrapchip.sv: $F112).
; This is the shape of exec's Signal(): under Disable() (INTENA only, so a
; request the CPU has already latched is still taken mid-sequence) a node
; is moved between two lists, a long word store at a time, while the
; supervisor stack -- where every interrupt frame goes -- is in Fast RAM.
; The level 2 handler walks and rewrites a list of its own when the main
; loop is not inside a "Disable", as exec's interrupt servers do.
; Both lists are checked forward and backward each round; the bench checks
; that every store reached DDR3 (its lost-write detector).
; The code runs from Fast RAM (copied there, position independent) with
; both caches on, as exec runs from cachable ROM: the handler is short
; enough that the main loop runs between interrupts.

FAST    equ     $200000
SSP     equ     FAST+$8000      ; the supervisor stack, as exec's, in Fast RAM
LA      equ     FAST+$1002      ; list headers, misaligned as ExecBase's
LB      equ     FAST+$1012
LH      equ     FAST+$1022      ; the handler's list
NODES   equ     FAST+$1100      ; 8 nodes, $22 bytes apart (misaligned too)
HNODES  equ     FAST+$1400      ; the handler's 4 nodes
DIS     equ     FAST+$1000      ; "Disable" nesting (word)
ROUNDS  equ     1500

CODE    equ     FAST+$10000     ; where the code runs

ck      macro                   ; \1 operand, \2 expected (with #), \3 test
        cmp.l   \2,\1
        beq.s   ok\@
        move.w  #\3,($f100).l
        bra.w   fail
ok\@:
        endm

        org     0
        dc.l    $7000,start
        rept    254
        dc.l    fail
        endr

start:
        move.w  #$2700,sr
        move.b  #$20,($e80048).l        ; Zorro II RAM at $200000
        lea     body(pc),a0             ; the code to Fast RAM, then run it there
        lea     (CODE).l,a1
        move.w  #(body_end-body)/2-1,d0
copy:   move.w  (a0)+,(a1)+
        dbra    d0,copy
        jmp     (CODE).l

body:
        lea     (SSP).l,sp
        lea     irq2(pc),a0
        move.l  a0,($68).w
        lea     fail(pc),a0             ; anything unexpected
        move.l  a0,($8).w
        move.l  a0,($c).w
        move.l  a0,($10).w
        move.l  #$80008000,d0           ; both caches on
        movec   d0,cacr
        clr.w   (DIS).l
        clr.l   (hcount).l
        lea     (LA).l,a0
        bsr     newlist
        lea     (LB).l,a0
        bsr     newlist
        lea     (LH).l,a0
        bsr     newlist
        ; LA: the eight nodes; LH: the handler's four
        lea     (NODES).l,a1
        moveq   #7,d7
fillA:  lea     (LA).l,a0
        move.b  d7,9(a1)                ; ln_Pri
        bsr     addtail
        lea     $22(a1),a1
        dbra    d7,fillA
        lea     (HNODES).l,a1
        moveq   #3,d7
fillH:  lea     (LH).l,a0
        bsr     addtail
        lea     $22(a1),a1
        dbra    d7,fillH

        move.w  #2000,($f114).l         ; an interrupt every 1..2000 clocks
        move.w  #2,($f112).l
        move.w  #$2000,sr

        move.l  #ROUNDS,d6
round:
        move.w  d6,($f10a).l            ; progress, for the bench
        ; Disable(); Remove(node) from LA; Enqueue(LB, node); Enable()
        move.l  d6,d0
        and.l   #7,d0
        mulu.w  #$22,d0
        lea     (NODES).l,a1
        add.l   d0,a1
        move.w  #$4000,($f124).l        ; (INTENA off: a chip bus write)
        addq.w  #1,(DIS).l
        bsr     find_in_la
        tst.l   d0
        beq.s   inlb
        bsr     remove
        lea     (LB).l,a0
        bsr     enqueue
        bra.s   moved
inlb:   bsr     remove                  ; it was in LB: back to LA's tail
        lea     (LA).l,a0
        bsr     addtail
moved:  subq.w  #1,(DIS).l
        move.w  #$c000,($f124).l        ; (INTENA on)
        ; every round: both lists whole, eight nodes between them
        lea     (LA).l,a0
        bsr     checklist
        move.l  d0,d5
        lea     (LB).l,a0
        bsr     checklist
        add.l   d0,d5
        ck      d5,#8,1
        subq.l  #1,d6
        bne     round

        move.w  #0,($f112).l            ; no more interrupts
        move.w  #$2700,sr
        lea     (LH).l,a0
        bsr     checklist
        ck      d0,#4,2
        move.l  (hcount).l,d0
        cmp.l   #300,d0                 ; the interrupts really happened
        bhi.s   enough
        move.w  #3,($f100).l
        bra.w   fail
enough:
        ; and memory agrees with the caches: push everything, caches off
        cpusha  bc
        moveq   #0,d0
        movec   d0,cacr
        lea     (LA).l,a0
        bsr     checklist
        move.l  d0,d5
        lea     (LB).l,a0
        bsr     checklist
        add.l   d0,d5
        ck      d5,#8,4
        lea     (LH).l,a0
        bsr     checklist
        ck      d0,#4,5
        move.w  #$600d,($f102).l
        bra.s   *

; level 2: ack; unless "disabled", rotate the handler's list (Remove the
; head, AddTail it): eight long word stores between the frame's
irq2:   move.w  #0,($f110).l
        movem.l d0/a0-a3,-(sp)
        addq.l  #1,(hcount).l
        tst.w   (DIS).l
        bne.s   irq2_out
        lea     (LH).l,a0
        move.l  (a0),a1
        bsr     remove
        bsr     addtail
irq2_out:
        movem.l (sp)+,d0/a0-a3
        rte

; exec's list primitives: list a0, node a1 (a2, a3 scratch)
newlist:
        lea     4(a0),a2
        move.l  a2,(a0)
        clr.l   4(a0)
        move.l  a0,8(a0)
        rts
addtail:
        move.l  8(a0),a2
        lea     4(a0),a3
        move.l  a3,(a1)
        move.l  a2,4(a1)
        move.l  a1,(a2)
        move.l  a1,8(a0)
        rts
remove:
        move.l  (a1),a2
        move.l  4(a1),a3
        move.l  a2,(a3)
        move.l  a3,4(a2)
        rts
; Enqueue by ln_Pri (exec's loop, then Insert before the node found)
enqueue:
        move.l  d1,-(sp)
        move.b  9(a1),d1
        move.l  (a0),d0
enq_lp: move.l  d0,a2
        move.l  (a2),d0
        beq.s   enq_in
        cmp.b   9(a2),d1
        ble.s   enq_lp
enq_in: move.l  4(a2),d0
        move.l  a1,4(a2)
        move.l  a2,(a1)
        move.l  d0,4(a1)
        move.l  d0,a3
        move.l  a1,(a3)
        move.l  (sp)+,d1
        rts
; d0 = 1 if a1 is on LA
find_in_la:
        lea     (LA).l,a2
        move.l  (a2),a3
fil_lp: tst.l   (a3)
        beq.s   fil_no
        cmp.l   a1,a3
        beq.s   fil_yes
        move.l  (a3),a3
        bra.s   fil_lp
fil_yes:
        moveq   #1,d0
        rts
fil_no: moveq   #0,d0
        rts
; walk list a0 forward checking every pred, then the tail: d0 = node count
checklist:
        movem.l a1-a3,-(sp)
        moveq   #0,d0
        move.l  a0,a2                   ; previous
        move.l  (a0),a1
cl_lp:  tst.l   (a1)
        beq.s   cl_end
        cmp.l   4(a1),a2
        bne.s   cl_bad
        move.l  a1,a2
        move.l  (a1),a1
        addq.l  #1,d0
        cmp.l   #64,d0
        bhi.s   cl_bad
        bra.s   cl_lp
cl_end: cmp.l   8(a0),a2                ; lh_TailPred: the last node
        bne.s   cl_bad
        movem.l (sp)+,a1-a3
        rts
cl_bad: move.w  #9,($f100).l
        bra.w   fail

fail:   move.w  #$bad0,($f102).l
        bra.s   *
body_end:

hcount  equ     FAST+$1040
