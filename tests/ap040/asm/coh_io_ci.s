; coh_io_ci: Control for coh_io: the same with DTT0 marking $00xxxxxx cache-
; inhibited.
; Passes with $600D at $F102; fails with 99.  Bench: tb_cpu_wrapper_chip
; (FASTRAM_CFG=4).  Assembled with vasmm68k_mot -Fbin -m68040.

 org 0
 dc.l $3400,start
 rept 254
 dc.l fail
 endr
 org $400
start:
 move.l #$0000C040,d0
 movec d0,dtt0
 move.w #$123,($B80108).l
 move.l #$80000000,d0
 movec d0,cacr
 move.w ($B80108).l,d0
 move.w #$F123,($B80108).l
 move.w ($B80108).l,d0
 move.w d0,($F174).l
 cmp.w #$0123,d0
 bne fail
pass:
 move.w #$600D,($F102).l
 stop #$2700
fail:
 move.w #99,($F100).l
 move.w #$BAD0,($F102).l
 stop #$2700
