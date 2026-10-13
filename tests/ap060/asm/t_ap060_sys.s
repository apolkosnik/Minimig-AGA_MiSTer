; The AP68060 in Minimig (tests/ap060/tb_ap060_wrapchip.sv): the 68060 bus
; through ap060_tg68k_compat and the real cpu_wrapper.
;   1-9    chip RAM: byte, word, long reads and writes split into 16-bit
;          accesses, odd byte lanes, read-modify-write of neighbours
;   10     Zorro II autoconfiguration ($E80048) maps the card at $200000
;   11-19  Fast RAM through the RAM port, the caches on: line fills of a
;          burst-inhibited line (TBI), write-through, long words across
;          the line
;   20-22  chip RAM is not cached (TCI): a rewrite by "DMA" (the bench,
;          no bus cycle) is seen by the next read
;   23     code executed from Fast RAM (instruction cache fills)
;   24-25  an autovectored level 3 interrupt (the acknowledge cycle is
;          answered by the adapter with AVEC)
;   26-28  an MC68LC060: FPU instructions take the disabled exception
;          (vector 11, format $4)

FAST    equ     $200000

ck      macro                   ; \1 operand, \2 expected (with #), \3 test
        cmp.l   \2,\1
        beq.s   ok\@
        move.w  #\3,($f100).l
        jmp     fail
ok\@:
        endm

        org     0
        dc.l    $7000,start
        rept    254
        dc.l    fail
        endr

start:
        move.w  #$2700,sr
        move.l  #irq3,($6c).w
        move.l  #fline,($2c).w

;------------------------------------------------ chip RAM
        lea     ($8000).l,a0
        move.l  #$11223344,(a0)
        move.l  (a0),d0
        ck      d0,#$11223344,1
        move.w  2(a0),d0
        and.l   #$ffff,d0
        ck      d0,#$3344,2
        move.b  #$aa,1(a0)              ; odd lane
        move.b  #$bb,2(a0)              ; even lane of the second word
        move.l  (a0),d0
        ck      d0,#$11aabb44,3
        move.b  3(a0),d0
        and.l   #$ff,d0
        ck      d0,#$44,4
        move.w  #$5566,2(a0)
        move.l  (a0),d0
        ck      d0,#$11aa5566,5
        lea     ($8100).l,a1
        moveq   #7,d1
cfill:  move.l  d1,(a1)+
        dbra    d1,cfill
        lea     ($8100).l,a1
        moveq   #7,d1
cchk:   move.l  (a1)+,d0
        cmp.l   d1,d0
        beq.s   cchk_ok
        move.w  #6,($f100).l
        jmp     fail
cchk_ok:
        dbra    d1,cchk

;------------------------------------------------ autoconfiguration
        move.b  #$20,($e80048).l        ; Zorro II RAM at $200000
        lea     (FAST).l,a0
        move.l  #$cafef00d,(a0)
        move.l  (a0),d0
        ck      d0,#$cafef00d,10

;------------------------------------------------ the caches on
        move.l  #$80008000,d0           ; CACR EDC, EIC
        movec   d0,cacr
        lea     (FAST+$100).l,a0
        moveq   #31,d1
ffill:  move.l  d1,d0
        mulu.w  #$1111,d0
        move.l  d0,(a0)+
        dbra    d1,ffill
        lea     (FAST+$100).l,a0
        moveq   #31,d1
fchk:   move.l  d1,d0
        mulu.w  #$1111,d0
        cmp.l   (a0)+,d0
        beq.s   fchk_ok
        move.w  #11,($f100).l
        jmp     fail
fchk_ok:
        dbra    d1,fchk
        ; hits on the lines just filled, and words and bytes inside them
        move.w  (FAST+$102).l,d0
        and.l   #$ffff,d0
        ck      d0,#$110f,12            ; 31 * $1111 = $0002110F, its low word
        move.b  (FAST+$107).l,d0
        and.l   #$ff,d0
        ck      d0,#$fe,13              ; 30 * $1111 = $0001FFFE, its low byte
        move.b  #$5a,(FAST+$107).l      ; write-through into a cached line
        move.l  (FAST+$104).l,d0
        ck      d0,#$0001ff5a,14
        ; ... and it reached the card: read with the data cache off
        movec   cacr,d0
        and.l   #$7fffffff,d0
        movec   d0,cacr
        move.l  (FAST+$104).l,d0
        ck      d0,#$0001ff5a,15
        move.l  #$80008000,d0
        movec   d0,cacr

;------------------------------------------------ chip RAM stays uncached
        move.l  #$12345678,($8000).l
        move.l  ($8000).l,d0            ; a line read here would cache it
        ck      d0,#$12345678,20
        move.w  #1,($f120).l            ; "DMA" rewrites it
        move.l  ($8000).l,d0
        ck      d0,#$edcba987,21
        move.w  #1,($f120).l
        move.l  ($8000).l,d0
        ck      d0,#$12345678,22

;------------------------------------------------ code in Fast RAM
        lea     fcode(pc),a0
        lea     (FAST+$1000).l,a1
        moveq   #(fcode_end-fcode)/2-1,d1
fcopy:  move.w  (a0)+,(a1)+
        dbra    d1,fcopy
        cpusha  bc                      ; push the copy, start the code clean
        moveq   #0,d0
        jsr     (FAST+$1000).l
        ck      d0,#$0000002a,23

;------------------------------------------------ an autovectored interrupt
        clr.l   (irqcnt).l
        move.w  #3,($f110).l            ; IPL 3
        move.w  #$2000,sr
        move.l  #2000,d1
wirq:   tst.l   (irqcnt).l
        bne.s   girq
        subq.l  #1,d1
        bne.s   wirq
        move.w  #24,($f100).l
        jmp     fail
girq:   move.w  #$2700,sr
        move.l  (irqcnt).l,d0
        ck      d0,#1,25

;------------------------------------------------ exec-style list work
; A list header (misaligned, as exec's TaskReady at ExecBase+$196) and
; task-sized nodes in Fast RAM, the caches on.  AddTail, Remove, AddHead
; as exec's list code writes them: four pointers each, a long word at a
; time, back to back.  The level 3 handler then moves a node, as Signal()
; from an interrupt server moves a task to TaskReady.  The pointers are
; checked through the cache, then from memory with the caches off.
LIST    equ     FAST+$2002      ; lh_Head lh_Tail lh_TailPred
NODEA   equ     FAST+$2100
NODEB   equ     FAST+$2142      ; misaligned node

        lea     (LIST).l,a0
        lea     4(a0),a1
        move.l  a1,(a0)         ; NEWLIST
        clr.l   4(a0)
        move.l  a0,8(a0)
        lea     (NODEA).l,a1
        bsr     addtail
        lea     (NODEB).l,a1
        bsr     addtail
        lea     (NODEA).l,a1
        bsr     remove
        bsr     addhead                 ; list = A B
        move.l  (LIST).l,d0
        ck      d0,#NODEA,40
        move.l  (NODEA).l,d0
        ck      d0,#NODEB,41
        move.l  (NODEA+4).l,d0
        ck      d0,#LIST,42
        move.l  (NODEB+4).l,d0
        ck      d0,#NODEA,43
        move.l  (NODEB).l,d0
        ck      d0,#LIST+4,44
        move.l  (LIST+8).l,d0
        ck      d0,#NODEB,45

        ; the handler: Remove(B), AddHead(B) -> list = B A
        move.l  #irq3_list,($6c).w
        clr.l   (irqcnt).l
        move.w  #3,($f110).l
        move.w  #$2000,sr
        move.l  #2000,d1
wirq2:  tst.l   (irqcnt).l
        bne.s   girq2
        subq.l  #1,d1
        bne.s   wirq2
        move.w  #46,($f100).l
        jmp     fail
girq2:  move.w  #$2700,sr
        bsr     chk_ba                  ; through the caches
        move.l  #$0fff0fff,d0           ; pointers are sticky, the rest
        cpusha  bc                      ; from memory: push, caches off
        moveq   #0,d0
        movec   d0,cacr
        bsr     chk_ba
        move.l  #$80008000,d0
        movec   d0,cacr

        ; a misaligned long word and its neighbours
        move.l  #$11111111,(FAST+$2200).l
        move.l  #$22222222,(FAST+$2204).l
        move.l  #$deadbeef,(FAST+$2202).l
        move.l  (FAST+$2200).l,d0
        ck      d0,#$1111dead,53
        move.l  (FAST+$2204).l,d0
        ck      d0,#$beef2222,54
        move.l  (FAST+$2202).l,d0
        ck      d0,#$deadbeef,55
        cpusha  bc
        moveq   #0,d0
        movec   d0,cacr
        move.l  (FAST+$2200).l,d0
        ck      d0,#$1111dead,56
        move.l  (FAST+$2204).l,d0
        ck      d0,#$beef2222,57
        move.l  #$80008000,d0
        movec   d0,cacr

;------------------------------------------------ the FPU, by PCR's ID
; $0430 an MC68060: FPU instructions execute; $0431 an MC68LC060: they take
; the disabled exception (vector 11, format $4, the instruction's PC)
        dc.w    $4e7a,$0808             ; movec pcr,d0
        swap    d0
        and.l   #$ffff,d0
        cmp.l   #$0430,d0
        beq.s   fpu_on
        ck      d0,#$0431,26
        clr.l   (flcnt).l
fi:     fmove.l #1,fp0
fn:     move.l  (flcnt).l,d0
        ck      d0,#1,27
        move.l  (flfv).l,d0
        ck      d0,#$402c,28
        move.l  (flpc).l,d0
        ck      d0,#fi,28
        bra.s   fpu_done
fpu_on: clr.l   (flcnt).l
        fmove.l #7,fp0
        fmul.l  #6,fp0
        fmove.l fp0,d0
        ck      d0,#42,29
        move.l  (flcnt).l,d0
        ck      d0,#0,30                ; no trap
fpu_done:

        move.w  #$600d,($f102).l
        bra.s   *

; exec's list primitives (list a0, node a1)
addtail:
        move.l  8(a0),a2        ; tailpred
        lea     4(a0),a3
        move.l  a3,(a1)         ; node.succ = &lh_Tail
        move.l  a2,4(a1)        ; node.pred = tailpred
        move.l  a1,(a2)         ; tailpred.succ = node
        move.l  a1,8(a0)        ; lh_TailPred = node
        rts
addhead:
        move.l  (a0),d0         ; old head
        move.l  d0,(a1)         ; node.succ
        move.l  a0,4(a1)        ; node.pred = list
        move.l  d0,a2
        move.l  a1,4(a2)        ; oldhead.pred = node
        move.l  a1,(a0)         ; lh_Head = node
        rts
remove:
        move.l  (a1),a2         ; succ
        move.l  4(a1),a3        ; pred
        move.l  a2,(a3)         ; pred.succ = succ
        move.l  a3,4(a2)        ; succ.pred = pred
        rts
; list = B A: every pointer, tests 47-52 (+6 for the memory pass)
chk_ba:
        move.l  (LIST).l,d0
        ck      d0,#NODEB,47
        move.l  (NODEB).l,d0
        ck      d0,#NODEA,48
        move.l  (NODEB+4).l,d0
        ck      d0,#LIST,49
        move.l  (NODEA+4).l,d0
        ck      d0,#NODEB,50
        move.l  (NODEA).l,d0
        ck      d0,#LIST+4,51
        move.l  (LIST+8).l,d0
        ck      d0,#NODEA,52
        rts

irq3_list:
        move.w  #0,($f110).l
        movem.l d0/a0-a3,-(sp)
        lea     (LIST).l,a0
        lea     (NODEB).l,a1
        bsr     remove
        bsr     addhead
        movem.l (sp)+,d0/a0-a3
        addq.l  #1,(irqcnt).l
        rte

; copied to Fast RAM and run from there
fcode:  moveq   #21,d0
        add.l   d0,d0
        rts
        nop
fcode_end:

irq3:   move.w  #0,($f110).l
        addq.l  #1,(irqcnt).l
        rte

fline:  move.w  6(sp),d7
        and.l   #$ffff,d7
        move.l  d7,(flfv).l
        move.l  12(sp),(flpc).l
        addq.l  #1,(flcnt).l
        rte

fail:   move.w  #$bad0,($f102).l
        bra.s   *

        even
irqcnt: dc.l    0
flcnt:  dc.l    0
flfv:   dc.l    0
flpc:   dc.l    0
