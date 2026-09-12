derive_pll_clocks
derive_clock_uncertainty

# P2 / FAST_CLOCK: the CPU is on clk_114 with a 4:1 core enable (Minimig.sv,
# cpu_wrapper CORE_DIV=4; the first fit at 2 missed by -16.2 ns on the
# address cone).  The cpu_inst* -> ram* relaxation that once stood here was
# a clk_sys->clk_114 CROSSING exception; both ends are clk_114 now and the
# RAM controllers sample every fast cycle, so it would be a false relaxation
# and is gone.
#
# What IS legitimately four cycles: a register that changes only on
# core_tick, driving a register that captures only on core_tick.  Every
# register in ap040_core, ap040_mmu, ap040_cache's FSM and ap040_bus16_adapter
# is one ("all outputs are registered and change only on clkena_in edges",
# the adapter's header; the cache and MMU FSMs run under ce).  cpu_wrapper's
# bus_timeout and the tg68k_compat core_stall_watchdog hold berr as a level
# until it is sampled on a qualified edge.  A RAM's write-enable and address
# input registers move only when their tick-gated drivers do, so RAMs are
# fine as SOURCES.
#
# RAM ports are EXCLUDED as DESTINATIONS, on purpose and by arithmetic.  A
# free-running read port re-samples its address every fast cycle, and the
# tick-gated consumer of its output reads what the port sampled one cycle
# before the tick.  An address that changed at tick T must therefore be
# right by the T+3 sample: three cycles, not four.  A four-cycle exception
# there would let the T+3 sample be garbage and hand the tick a wrong tag or
# a wrong translation.  The ATC's write port is the same shape (address,
# data and enable from the walker, sampled T+1).  So every destination set
# below is "block minus *ram_block*"; if a RAM-port path ever fails, it gets
# a multicycle of THREE with this derivation, not a widening of these.
#
# What no exception may touch: the RAM controllers' acknowledge into
# core_enable -- the clock enable of every tick-gated register (cpu_wrapper
# bus_complete).  A late enable at a tick is torn state, not a late value.
# Measured at -2.4 ns (report_timing, 00db688b); it closes by registering
# bus_complete once in the wrapper, an RTL change against ram_cs_guard's
# age contract, taken separately.  Likewise core|state -> core|epf_* at
# -3.6 inside its 35 ns: already relaxed, an RTL cone if it persists.
#
# The one free-running endpoint reached from outside the cache is
# look_snooped, via its acceptance-cycle term (ap040_cache.v).  It is in the
# cache set below on PROOF: tb_ap040_cache_snoop under the silicon-faithful
# tag-row model with +inj_acc_whole -- that term blind for its entire window
# -- FAILS at CE_DIV 1 and PASSES at CE_DIV 4, because at divide 4 the row is
# re-read every cycle and any collision is cleaned before the compare four
# cycles on.  The term may be arbitrarily late under this enable; the
# compare-cycle term, which carries the load at divide 4, reads only the
# captured row.  Both flags have zero paths into the core (checked).
#
# Sources and sinks, every pair below read off one report_timing pass over
# the block matrix on the 00db688b fit (scratchpad sta_matrix.tcl), each
# negative there and each with the reason above.  Collections are checked
# non-empty by the pre-build STA script; an unmatched filter is a silent
# no-op, which is how two of these were first written one level short.
set P {emu|cpu_wrapper|cpu_inst_p}
set CORE      [get_registers "$P|core|*"]
set MMU_ALL   [get_registers "$P|mmu|*"]
set MMU_R     [remove_from_collection $MMU_ALL   [get_registers "$P|mmu|*ram_block*"]]
set CACHE_ALL [get_registers "$P|g_cache.cache|*"]
set CACHE_R   [remove_from_collection $CACHE_ALL [get_registers "$P|g_cache.cache|*ram_block*"]]
set BUS16     [get_registers "$P|bus16|*"]
set WDOG      [get_registers "$P|core_stall_watchdog|*"]
set WTMO      [get_registers {emu|cpu_wrapper|bus_timeout|*}]
foreach {from to} [list \
    CORE CORE   CORE MMU_R   CORE CACHE_R   CORE BUS16 \
    MMU_ALL CORE   MMU_ALL MMU_R   MMU_ALL CACHE_R   MMU_ALL BUS16 \
    CACHE_ALL CORE   CACHE_ALL CACHE_R   CACHE_ALL BUS16 \
    BUS16 CORE   BUS16 MMU_R   BUS16 CACHE_R   BUS16 BUS16 \
    WDOG CORE   WTMO CORE ] {
    set_multicycle_path -from [set $from] -to [set $to] -setup 4
    set_multicycle_path -from [set $from] -to [set $to] -hold 3
}

set_multicycle_path -from {emu|amiga_clk|cck*} -to {emu|ram1|*} -setup 2
set_multicycle_path -from {emu|amiga_clk|cck*} -to {emu|ram1|*} -hold 1
set_multicycle_path -from {emu|minimig|*} -to {emu|ram1|*} -setup 2
set_multicycle_path -from {emu|minimig|*} -to {emu|ram1|*} -hold 1

# CD32 Akiko PBX address path to SDRAM. pbx_byte_idx only advances on dma_ack,
# which fires at most once per 6+ emu-clk cycles (chipdma_arb's S_DRIVE takes 4
# cycles minimum). Address is stable for well over 2 launch-clk cycles before
# the next update, so a 2-cycle setup multicycle is safe. Mirrors the existing
# emu|minimig|* -> emu|ram1|* relaxation. Without this, pbx_seccnt -> sd_addr
# violates by ~2.5 ns.
set_multicycle_path -from {emu|fastchip|akiko|*} -to {emu|ram1|*} -setup 2
set_multicycle_path -from {emu|fastchip|akiko|*} -to {emu|ram1|*} -hold 1
set_multicycle_path -from {emu|chipdma_arb|*}    -to {emu|ram1|*} -setup 2
set_multicycle_path -from {emu|chipdma_arb|*}    -to {emu|ram1|*} -hold 1

# The retained CD DMA write word can have an exceptionally short route to
# SDRAM's datawr register (seed 1: -0.149 ns hold in the fast timing model).
# The arbiter supplies explicit buffer cells; require 0.25 ns extra hold
# margin as well. This tightens the minimum arrival requirement while
# leaving the setup multicycles unchanged.
set_min_delay 0.25 -from [get_registers {*chipdma_arb*ak_wr_data*}] \
                  -to [get_registers {*ram1*datawr*}]

# amiga_clk c1/c3 are the 7 MHz-rate phase regs in the 28 MHz (clk_28) domain
# (c1 <= ~c3). The chip-arming address path launches from c1, passes through
# chipdma_arb combinational logic, and lands on sdram_ctrl.sd_addr captured by
# the 113 MHz SDRAM clock. -from matches the LAUNCH register (c1), not the
# chipdma_arb pass-through nodes, so the chipdma_arb|* and cck* relaxations
# above do NOT cover it and sd_addr violates by -0.49 ns. clk_114:clk_28 is
# 4:1; sdram_ctrl edge-detects ~old_7m&c_7m (sdram_ctrl.v:237-243), so a c1
# launch at fast edge N is detected at N+1 and the state-0 RAS capture
# (sdram_ctrl.v:301-318) is at N+2 — exactly 2 clk_114 cycles, never the
# adjacent edge. setup 2 matches; setup >= 3 would NOT be safe.
set_multicycle_path -from {emu|amiga_clk|c1*} -to {emu|ram1|*} -setup 2
set_multicycle_path -from {emu|amiga_clk|c1*} -to {emu|ram1|*} -hold 1
set_multicycle_path -from {emu|amiga_clk|c3*} -to {emu|ram1|*} -setup 2
set_multicycle_path -from {emu|amiga_clk|c3*} -to {emu|ram1|*} -hold 1

# Bridge DMA write port on ram2 (DDR3) is a CDC handshake. chipdma_arb
# (clk_sys) registers dma_ddr_cs_r plus the entire DDR bus (addr / wr / l / u)
# on arm_now and holds them stable until S_ACK. ddram_ctrl (clk_114)
# synchronizes dmaCS through a 2-FF chain, edge-detects the rise, and latches
# data on that edge — by which point the data has been valid in chipdma_arb
# for many clk_114 cycles. dmaACK comes back as a level, synchronized by a
# 2-FF chain inside chipdma_arb.
#
# dmaCS is therefore the only cross-domain bit that needs timing, and its sync
# chain handles metastability. The data lines are stable by handshake, so
# set_false_path is correct.
set_false_path -from {*chipdma_arb*dma_ddr_addr_r*} -to {*ddram_ctrl*}
set_false_path -from {*chipdma_arb*dma_ddr_wr_r*}   -to {*ddram_ctrl*}
set_false_path -from {*chipdma_arb*dma_ddr_l_r*}    -to {*ddram_ctrl*}
set_false_path -from {*chipdma_arb*dma_ddr_u_r*}    -to {*ddram_ctrl*}
# Also false_path the two CDC sync first-stages. dma_ddr_cs_r -> dmaCS_sync1
# is the slow->fast (clk_sys -> clk_114) handshake; dmaACK_r ->
# ddr_in_ack_sync1 is the reverse. Both are absorbed by 2-FF synchronizer
# chains in their target domains. Without this, Quartus times them at a single
# cycle and reports -3.7 ns slack.
set_false_path -from {*chipdma_arb*dma_ddr_cs_r*}   -to {*ddram_ctrl*dmaCS_sync*}
set_false_path -from {*ddram_ctrl*dmaACK_r*}        -to {*chipdma_arb*ddr_in_ack_sync*}

set_false_path -from {emu|cpu_wrapper|z3ram_*}
set_false_path -from {emu|cpu_wrapper|z2ram_*}

# Framework: emu|hps_io|status (the HPS-written OSD status word) -> ary (the
# aspect-ratio config register in sys_top).  Both quasi-static: written when
# the user changes a setting, read continuously.  Round 3 (80c30bef) showed
# -0.058 ns HOLD in the fast/-40C corner -- placement variance on a path with
# no margin to begin with, and the same class sys_top.sdc already false-paths
# in the other direction (from {arx* ary*}).  Blocked the gate as an emu-domain
# negative; a one-frame glitch on an aspect change is the worst case.
set_false_path -from {emu|hps_io|status*} -to {ary*}

set_false_path -from {emu|minimig|USERIO1|cpu_config*}
set_false_path -from {emu|minimig|USERIO1|ide_config*}
set_false_path -from {emu|minimig|USERIO1|bootrom}
set_false_path -from {emu|minimig|CPU1|halt}

# A2065: the card's 68k side (clk_sys) reaches its DDR3 mailbox (DDRAM_CLK,
# clk_114) over 2-FF level-detect CDC handshakes inside a2065_regfile and
# a2065_ddram. Those are self-timed and need no multicycle exception. If the
# fitter reports real violations across that boundary, add a targeted
# set_false_path/set_max_delay derived from report_timing — do not guess.

# yc_out chroma LUT: multicycle retained from the old bridge, where boardram BRAM
# placement congestion pushed this path to -0.471ns. The flat-DDR3 design removes
# that BRAM, so this exception may now be UNNECESSARY. Re-validate against the
# merged fitter run (R3); keep only if report_timing still shows the path marginal.
set_multicycle_path -from {yc_out|chroma_LUT_BURST[*]} \
                    -to   {yc_out|phase[*].u[*]} -setup 2
set_multicycle_path -from {yc_out|chroma_LUT_BURST[*]} \
                    -to   {yc_out|phase[*].u[*]} -hold 1

# emu PLL cross-clock: counter[1]→counter[0] marginal path
set_multicycle_path -setup 2 -from [get_clocks "emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter\[1\].output_counter|divclk"] -to [get_clocks "emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter\[0\].output_counter|divclk"]
set_multicycle_path -hold 1 -from [get_clocks "emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter\[1\].output_counter|divclk"] -to [get_clocks "emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter\[0\].output_counter|divclk"]

#these constraints aren't really correct, but help fitting.
#28MHz pixel clock might be affected when scandoubler fx is used.
set_multicycle_path -to {*Hq2x*} -setup 2
set_multicycle_path -to {*Hq2x*} -hold 1
set_multicycle_path -from [get_clocks { *|pll|pll_inst|altera_pll_i|*[0].*|divclk}] -to {ascal|*} -setup 2
set_multicycle_path -from [get_clocks { *|pll|pll_inst|altera_pll_i|*[0].*|divclk}] -to {ascal|*} -hold 1
