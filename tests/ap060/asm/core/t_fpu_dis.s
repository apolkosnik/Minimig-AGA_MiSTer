; MC68060 floating-point disabled exception (MC68060UM 8.2.4, 8.4.4):
; PCR.DFP set, or an MC68LC060 (no FPU, PCR ID $0431).  Every instruction
; the FPU recognises takes vector 11 with a format $4 frame:
;   +$00 SR   +$02 PC of the next instruction   +$06 $402C
;   +$08 the operand's effective address (0: register, immediate, none;
;        -(An) of a 12-byte operand: An - 4)
;   +$0C the PC of the floating-point instruction
; before any side effect: (An)+ and -(An) are not updated, nothing is
; stored.  Words the FPU does not recognise keep the F-line exception
; (format $0, PC of the word).  Then DFP is cleared: a 68060 executes FPU
; instructions again, a 68LC060 still traps them.
;
; FMOVEM (An)+/-(An), FSAVE and FRESTORE report EA 0 (the core has no FPU
; step with their address; documented in rtl/ap68060_fpif.sv).

DATA    equ     $4000
LOG     equ     $3000           ; SR.w PC.l FV.w EA.l FPC.l
CNT     equ     $3010
SKIP    equ     $3014           ; format $0 F-line: bytes to step over

ck      macro                   ; \1 operand, \2 expected (with #), \3 test
        cmp.l   \2,\1
        beq.s   ok\@
        move.w  #\3,($f100).l
        jmp     fail
ok\@:
        endm
; the frame of the disabled exception taken by the instruction at \1
; (next instruction \2), EA \3, test number \4
dis     macro
        addq.l  #1,d6
        move.l  (CNT).l,d0
        ck      d0,d6,\4
        move.w  (LOG+6).l,d0
        and.l   #$ffff,d0
        ck      d0,#$402c,\4+100
        move.l  (LOG+2).l,d0
        ck      d0,#\2,\4+200
        move.l  (LOG+12).l,d0
        ck      d0,#\1,\4+300
        move.l  (LOG+8).l,d0
        ck      d0,#\3,\4+400
        endm

        org     0
        dc.l    $e000,start
        rept    254
        dc.l    fail
        endr
start:
        move.w  #$2700,sr
        move.l  #fline_handler,($2c).w
        clr.l   (CNT).l
        moveq   #0,d6
        lea     (DATA).l,a2
        moveq   #31,d0
fill:   move.l  #$a5a5a5a5,(a2)+
        dbra    d0,fill

        dc.w    $4e7a,$0808     ; movec pcr,d0
        move.l  d0,d5           ; d5: PCR as reset left it
        bset    #1,d0           ; DFP
        dc.w    $4e7b,$0808     ; movec d0,pcr

;------------------------------------------------ registers, immediates
i1:     fadd.x  fp1,fp0
n1:     dis     i1,n1,0,1
i2:     fmove.l #5,fp0
n2:     dis     i2,n2,0,2
        moveq   #3,d0
i3:     fmove.l d0,fp0
n3:     dis     i3,n3,0,3
i4:     fmovecr #0,fp0
n4:     dis     i4,n4,0,4

;------------------------------------------------ memory operands
        lea     (DATA).l,a0
i5:     fmove.l (a0),fp0
n5:     dis     i5,n5,DATA,5
i6:     fmove.x (a0)+,fp1
n6:     dis     i6,n6,DATA,6
        move.l  a0,d0
        ck      d0,#DATA,7              ; (An)+ not updated
        lea     (DATA+$10).l,a0
i8:     fmove.x -(a0),fp1
n8:     dis     i8,n8,DATA+$10-4,8      ; 12 bytes: An - 4
        move.l  a0,d0
        ck      d0,#DATA+$10,9          ; -(An) not updated
i10:    fmove.d fp0,-(a0)
n10:    dis     i10,n10,DATA+$10-8,10
        move.l  a0,d0
        ck      d0,#DATA+$10,11
        move.l  (DATA+8).l,d0
        ck      d0,#$a5a5a5a5,12        ; nothing stored
        lea     (DATA).l,a0
i13:    fmove.x fp0,(a0)
n13:    dis     i13,n13,DATA,13
        move.l  (DATA).l,d0
        ck      d0,#$a5a5a5a5,14
i15:    fmove.s $10(a0),fp2
n15:    dis     i15,n15,DATA+$10,15

;------------------------------------------------ control registers, FMOVEM
i16:    fmove.l fpcr,(a0)
n16:    dis     i16,n16,DATA,16
        move.l  (DATA).l,d0
        ck      d0,#$a5a5a5a5,17
i18:    fmove.l (a0),fpsr
n18:    dis     i18,n18,DATA,18
i19:    fmovem.x (a0),fp0-fp1
n19:    dis     i19,n19,DATA,19
        lea     (DATA+$40).l,a0
i20:    fmovem.x fp0-fp1,-(a0)
n20:    dis     i20,n20,0,20
        move.l  a0,d0
        ck      d0,#DATA+$40,21

;------------------------------------------------ conditionals
        lea     (DATA+$20).l,a1
i22:    fsne    (a1)
n22:    dis     i22,n22,DATA+$20,22
        move.l  (DATA+$20).l,d0
        ck      d0,#$a5a5a5a5,23        ; FScc stored nothing
i24:    fsne    d2
n24:    dis     i24,n24,0,24
i25:    fbeq.w  fail
n25:    dis     i25,n25,0,25
        moveq   #5,d1
i26:    fdbeq   d1,fail
n26:    dis     i26,n26,0,26
        ck      d1,#5,27                ; FDBcc's counter not decremented
i28:    ftrapeq.w #1
n28:    dis     i28,n28,0,28
i29:    fnop
n29:    dis     i29,n29,0,29

;------------------------------------------------ FSAVE, FRESTORE
        lea     (DATA).l,a0
i30:    fsave   (a0)
n30:    dis     i30,n30,0,30
        move.l  (DATA).l,d0
        ck      d0,#$a5a5a5a5,31
i32:    frestore (a0)
n32:    dis     i32,n32,0,32

;------------------------------------------------ not an FPU instruction
        move.l  #4,(SKIP).l
i33:    dc.w    $f200,$2000             ; opclass 001: F-line, format $0
n33:
        addq.l  #1,d6
        move.l  (CNT).l,d0
        ck      d0,d6,33
        move.w  (LOG+6).l,d0
        and.l   #$ffff,d0
        ck      d0,#$002c,34
        move.l  (LOG+2).l,d0
        ck      d0,#i33,35

;------------------------------------------------ DFP cleared
        move.l  d5,d0
        bclr    #1,d0
        dc.w    $4e7b,$0808             ; movec d0,pcr
        swap    d5
        cmp.w   #$0431,d5
        beq     lc060
        cmp.w   #$0430,d5
        beq     fpu060
        move.w  #36,($f100).l
        jmp     fail
fpu060:
        fmove.l #7,fp0
        fmove.l fp0,d0
        ck      d0,#7,37
        move.l  (CNT).l,d0
        ck      d0,d6,38                ; no exception
        bra     pass
lc060:
i39:    fmove.l #7,fp0                  ; no FPU: disabled whatever DFP is
n39:    dis     i39,n39,0,39

pass:
        move.w  #$600d,($f102).l
        bra.s   *

; vector 11: log the frame; a format $0 F-line steps over the word
fline_handler:
        movem.l d0/a0,-(sp)
        lea     (LOG).l,a0
        move.w  8(sp),(a0)
        move.l  10(sp),2(a0)
        move.w  14(sp),6(a0)
        move.w  14(sp),d0
        and.w   #$f000,d0
        bne.s   fl_f4
        move.l  (SKIP).l,d0
        add.l   d0,10(sp)
        clr.l   8(a0)
        clr.l   12(a0)
        bra.s   fl_done
fl_f4:  move.l  16(sp),8(a0)
        move.l  20(sp),12(a0)
fl_done:
        addq.l  #1,(CNT).l
        movem.l (sp)+,d0/a0
        rte

fail:
        move.w  #$bad0,($f102).l
        bra.s   *
