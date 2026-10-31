; The AP68060 in Minimig: RESET after a posted chipset write.  The adapter
; acknowledges a write once it is queued for cpu_wrapper (posted), so RESET
; can execute while that write still waits for the chip bus; RSTO must not
; reach the chipset (cpu_wrapper's reset_out) before it is done.  The bench
; fails the run if RSTO asserts with a request queued or a chip-bus cycle
; open.  From Fast RAM, as the audit found it: a chip RAM store, RESET.

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

; RESET also resets the autoconfiguration (cpu_wrapper: Fast RAM is gone,
; as on an Amiga), and anything after it would only be a fetch that waits
; behind the posted write (reads are in order) and holds RESET back: so,
; as in the audit, the program stops at RESET and the bench ($F12E) ends
; the run when RSTO asserts -- PASS if nothing posted is unfinished and the
; store is in chip RAM.  The bench holds the store's chip-bus cycle 400
; clocks ($F12C), as busy chipset DMA would.
        cnop    0,4
image:
        move.w  #1,($f12e).l            ; end the run at RSTO
        move.w  #400,($f12c).l          ; the next chip-bus cycle: slow
        move.w  #$1234,($8100).l        ; posted, still on the bus ...
        reset                           ; ... when RESET runs
spin:   bra.s   spin
image_end:
