; coh_smc_ci: Control for coh_smc: the same with ITT0 marking $00xxxxxx cache-
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
 movec d0,itt0
 move.w #$7001,($2000).l
 move.w #$4E75,($2002).l
 move.l #$8000,d0
 movec d0,cacr
 jsr ($2000).l
 move.w #$7002,($2000).l
 jsr ($2000).l
 move.w d0,($F174).l
 cmp.l #2,d0
 bne fail
pass:
 move.w #$600D,($F102).l
 stop #$2700
fail:
 move.w #99,($F100).l
 move.w #$BAD0,($F102).l
 stop #$2700
