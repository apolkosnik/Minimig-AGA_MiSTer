; Audit repro: two requests must produce exactly two interrupt entries.
; Code/stack live in the configured $08000000 Fast RAM window. The bench
; maps that window onto its flat RAM. $00dff110 is a SYNTHETIC IRQ device,
; not a model of the Amiga register at that address. Clearing it can wait.
; The first interrupt warms the handler and frame. SP=2 mod 4 makes the
; stacked PC aligned, so RTE can hit in cache without draining the write.
; NOP must synchronize pending bus operations (MC68040 UM 7.7).

 org 0
 dc.l $08008002,start+$08000000
 org $68
 dc.l handler+$08000000
 org $400
start:
 move.w #$2700,sr
 move.l #$80008000,d0
 movec d0,cacr
 move.l #$0000c040,d0
 movec d0,dtt0
 moveq #0,d6
 move.w #$2000,sr
 move.w #2,$00dff110
wait1:
 tst.l d6
 beq.s wait1
 move.w #1000,d0
pause1:
 dbra d0,pause1
 move.w #2,$00dff110
wait2:
 cmp.l #2,d6
 blo.s wait2
 move.w #1000,d0
pause2:
 dbra d0,pause2
 move.w #$2700,sr
 cmp.l #2,d6
 bne.s fail
 move.w #$600d,$f102
 bra.s *
fail:
 move.w d6,$f100
 move.w #$bad0,$f102
 bra.s *
 cnop 0,16
handler:
 addq.l #1,d6
 clr.w $00dff110
 nop
 rte
