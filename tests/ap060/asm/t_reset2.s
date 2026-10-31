; The AP68060 in Minimig: what follows RESET waits for the external reset.
; RSTO reaches the chipset (cpu_wrapper's reset_out) only once the posted
; writes before RESET are done, so it can come after the processor's own
; RSTO has ended; a peripheral write the processor makes after RESET must
; not land before that external reset is over, or the reset clears it.
; From the bus audit: from Fast RAM, a chip RAM store held on the chip bus
; for 400 clocks ($F12C), RESET, then the RTG enable ($B80106, cleared by
; the reset) written; from chip RAM afterwards the enable must read 1.
; (RESET also resets the autoconfiguration, so after it the Fast RAM part
; runs from the instruction cache: one fetch run, two lines.)

FAST    equ     $200000

        org     0
        dc.l    $7000,start
        rept    254
        dc.l    fail
        endr

        org     $400
start:
        move.w  #$2700,sr
        move.b  #$20,($e80048).l        ; Zorro II RAM at $200000
        lea     image(pc),a0
        lea     (FAST).l,a1
        moveq   #(image_end-image)/2-1,d0
copy:   move.w  (a0)+,(a1)+
        dbra    d0,copy
        move.l  #$8000,d0               ; instruction cache
        movec   d0,cacr
        jmp     (FAST).l
fail:
        move.w  #$BAD0,($f102).l
        bra.s   fail

        cnop    0,4
image:
        move.w  #400,($f12c).l          ; the next chip-bus cycle: slow
        move.w  #$1234,($8100).l        ; posted: RSTO waits for it
        reset
        move.w  #1,($b80106).l          ; RTG enable, after RESET
        move.w  #2000,d0                ; (from the instruction cache)
dly:    dbra    d0,dly
        jmp     (after).l
image_end:

after:
        move.w  ($b80106).l,d0          ; the enable survived the reset
        btst    #0,d0
        beq.s   bad
        cmp.w   #$1234,($8100).l
        bne.s   bad
        move.w  #$600D,($f102).l
done:   bra.s   done
bad:    move.w  #1,($f100).l
        move.w  #$BAD0,($f102).l
        bra.s   done
