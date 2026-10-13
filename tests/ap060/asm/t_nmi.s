; The AP68060 in Minimig: the level 7 interrupt as the Action Replay /
; HRTmon cartridge raises it (cart.v, modelled by the bench at $F118): its
; request is held until the processor's acknowledge read of $FFFFFE on the
; chip bus -- TG68K's acknowledge cycle -- which also arms the cartridge.
;   1  the NMI is taken (vector 31), the handler leaves the request alone,
;      as exec's does
;   2  the acknowledge read of level 7 appeared on the chip bus ($F200)
;   3  the request is gone: a level 3 interrupt is taken afterwards
;      (with the request still held, level 7 would mask it)
;   4  that one's acknowledge read was level 3

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
        move.l  #nmi,($7c).w
        move.l  #irq3,($6c).w
        clr.l   (nmicnt).l
        clr.l   (irqcnt).l
        clr.w   ($f200).l

        move.w  #1,($f118).l            ; the cartridge's NMI
        move.l  #2000,d1
wnmi:   tst.l   (nmicnt).l
        bne.s   gnmi
        subq.l  #1,d1
        bne.s   wnmi
        move.w  #1,($f100).l
        jmp     fail
gnmi:   move.w  ($f200).l,d0
        and.l   #$ffff,d0
        ck      d0,#7,2

        clr.w   ($f200).l
        move.w  #3,($f110).l
        move.w  #$2000,sr               ; levels 1-6 allowed
        move.l  #2000,d1
wirq:   tst.l   (irqcnt).l
        bne.s   girq
        subq.l  #1,d1
        bne.s   wirq
        move.w  #3,($f100).l
        jmp     fail
girq:   move.w  #$2700,sr
        move.w  ($f200).l,d0
        and.l   #$ffff,d0
        ck      d0,#3,4
        move.l  (nmicnt).l,d0
        ck      d0,#1,5                 ; one NMI: level 7 is edge-triggered

        move.w  #$600d,($f102).l
        bra.s   *

nmi:    addq.l  #1,(nmicnt).l           ; (exec-style: no acknowledge write)
        rte
irq3:   move.w  #0,($f110).l
        addq.l  #1,(irqcnt).l
        rte

fail:   move.w  #$bad0,($f102).l
        bra.s   *

        even
nmicnt: dc.l    0
irqcnt: dc.l    0
