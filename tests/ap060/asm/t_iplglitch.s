; The AP68060 in Minimig: no interrupt at a level that was never raised.
; The main loop waits in STOP #$2000, as HRTmon's idle loop does with only
; VBlank enabled; the bench raises level 3 at random points ($F112) and the
; handler drops it ($F110 = 0).  A stopped processor takes the first level
; above its mask it samples, so an intermediate one would be taken.  IPL is
; active low: 0 -> 3 is %111 -> %100.  Built with AP060_SIM_IPL_SKEW the
; adapter's IPL0 reaches its synchroniser late, as a bit resolving a clock
; later would on the FPGA, so 0 -> 3 can pass through %101 (level 2) for a
; clock -- above the mask, so taken.  (The 3 -> 0 drop happens inside the
; level 3 handler, at mask 3, where an intermediate level is ignored.)
; Levels 1 and 2 count such phantoms: there must be none.

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
        move.l  #irq1,($64).w
        move.l  #irq1,($68).w           ; level 2: a phantom too
        move.l  #irq3,($6c).w
        clr.l   (cnt1).l
        clr.l   (cnt3).l
        move.w  #2000,($f114).l         ; every 1..2000 clocks (the handler, run
                                        ; from chip RAM, takes ~1500: closer
                                        ; interrupts starve the main loop)
        move.w  #3,($f112).l
        move.w  #$2000,sr
wait:   stop    #$2000
        move.l  (cnt3).l,d0
        cmp.l   #300,d0
        blo.s   wait
        move.w  #$2700,sr
        move.w  #0,($f112).l
        move.l  (cnt1).l,d0
        ck      d0,#0,1                 ; no phantom level 1 or 2

        move.w  #$600d,($f102).l
        bra.s   *

irq3:   move.w  #0,($f110).l            ; IPL 3 -> 0
        addq.l  #1,(cnt3).l
        rte
irq1:   addq.l  #1,(cnt1).l
        rte

fail:   move.w  #$bad0,($f102).l
        bra.s   *

        even
cnt1:   dc.l    0
cnt3:   dc.l    0
