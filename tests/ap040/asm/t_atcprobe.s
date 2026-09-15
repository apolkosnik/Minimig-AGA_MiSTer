; Probe: after a failed table search, does a repaired descriptor take effect
; WITHOUT a PFLUSH?
;
; WinUAE's 68040 model creates an ATC entry even when the search fails
; (cpummu.cpp mmu_fill_atc: "68040 always creates ATC entry"), storing
; status 0 with valid set, and its lookup faults on a valid entry whose R
; bit is clear without starting a new search.  So on a 68040 the repair
; does NOT take effect until the entry is flushed.
;
; THIS CORE DOES NOT DO THAT, and the test pins the difference rather than
; hiding it.  A failed search leaves no entry here, so the next access
; searches again and the repair takes effect immediately: the count is 1,
; where a 68040 would fault a second time and need the PFLUSH the handler
; only issues on the second entry.
;
; The deviation is permissive -- every OS PFLUSHes after changing a
; mapping, so both behave identically for real software -- and matching the
; 68040 costs an R bit in the ATC entry, which is 46 bits where the payload
; RAM is built for 45.  If that is ever spent, this test flips to expecting
; 2 and that is the signal the change landed.

FAILREG         equ $F100
DONEREG         equ $F102
cnt_aerr        equ $3600

        org     0
        dc.l    $3400,start
        dc.l    h_aerr
        rept    253
        dc.l    unexpected
        endr

        org     $400
start:
        move.w  #$2700,sr
        clr.w   (cnt_aerr).l

        lea     ($4400).l,a0
        moveq   #0,d0
        moveq   #63,d1
tloop:
        move.l  d0,d2
        lsl.l   #8,d2
        lsl.l   #4,d2
        addq.l  #3,d2
        move.l  d2,(a0)+
        addq.l  #1,d0
        dbra    d1,tloop
        move.l  #$00004203,($4000).l
        move.l  #$00004403,($4200).l
        move.l  #$5A5A1234,($9000).l
        move.l  #$00000000,($4424).l    ; page 9: INVALID descriptor

        move.l  #$4000,d0
        movec   d0,urp
        movec   d0,srp
        move.l  #$8000,d0
        movec   d0,tc
        pflusha

        moveq   #0,d1
        move.l  ($9000).l,d1            ; faults: page 9 is invalid

        ; Reached only after the handler repaired the descriptor.  Which
        ; repair got us here is what the count says.
        cmp.l   #$5A5A1234,d1
        bne     f9
        moveq   #0,d0
        movec   d0,tc
        pflusha
        cmpi.w  #1,(cnt_aerr).l
        bne     f2                      ; 2 faults = the PFLUSH was needed
        move.w  #$600D,(DONEREG).l      ; 1 fault  = the repair took effect
        stop    #$2700

h_aerr:
        cmpi.w  #$7008,6(sp)
        bne     unexpected
        addq.w  #1,(cnt_aerr).l
        move.l  #$00009003,($4424).l    ; make it valid
        cmpi.w  #2,(cnt_aerr).l
        bne     h_noflush
        pflusha                         ; second time: flush and let it run
h_noflush:
        rte

f2:     moveq   #2,d7
        bra     f1
f1:     move.w  d7,(FAILREG).l
        move.w  #$BAD0,(DONEREG).l
        bra     halt
f9:     moveq   #9,d7
        bra     f1
halt:   bra     halt
unexpected:
        moveq   #15,d7
        bra     f1
