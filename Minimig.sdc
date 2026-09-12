derive_pll_clocks
derive_clock_uncertainty

# P2 / FAST_CLOCK: the CPU is on clk_114 with a 4:1 core enable (Minimig.sv,
# cpu_wrapper CORE_DIV=4; the first fit at 2 missed by -16.2 ns on the
# address cone, see the Minimig.sv comment).  The cpu_inst* -> ram* relaxation that stood here
# was a clk_sys->clk_114 CROSSING exception; both ends are clk_114 now and a
# same-domain setup-2 on that path would be a false relaxation -- the RAM
# controllers sample cpuCS and the address on every fast cycle, tick-aligned
# or not.  It is removed, not rewritten.
#
# What IS legitimately multicycle is the core_tick-gated hierarchy talking
# to itself: every register in ap040_core (and its regfile/alu/muldiv/fpu
# children) and in ap040_mmu advances only on core_tick, i.e. every fourth
# clk_114 edge, so a path between two of them has four cycles -- the same
# 35 ns the core was designed to at 28 MHz single-cycle.  Scope is
# deliberately narrow.  NOT the cache: ap040_cache's tag and data RAMs read
# every cycle and its compare consumes those outputs (PERFORMANCE.md: "a
# blanket four-cycle exception would incorrectly relax those paths").  NOT
# the wrapper: g_sync_chip runs every fast cycle.  NOT bus16: unproven,
# left single-cycle until report_timing says otherwise.  Derive any further
# relaxation from report_timing on a real fit -- do not widen this by hand.
set_multicycle_path -from {emu|cpu_wrapper|cpu_inst_p|core|*} -to {emu|cpu_wrapper|cpu_inst_p|core|*} -setup 4
set_multicycle_path -from {emu|cpu_wrapper|cpu_inst_p|core|*} -to {emu|cpu_wrapper|cpu_inst_p|core|*} -hold 3
set_multicycle_path -from {emu|cpu_wrapper|cpu_inst_p|mmu|*}  -to {emu|cpu_wrapper|cpu_inst_p|mmu|*}  -setup 4
set_multicycle_path -from {emu|cpu_wrapper|cpu_inst_p|mmu|*}  -to {emu|cpu_wrapper|cpu_inst_p|mmu|*}  -hold 3
set_multicycle_path -from {emu|cpu_wrapper|cpu_inst_p|core|*} -to {emu|cpu_wrapper|cpu_inst_p|mmu|*}  -setup 4
set_multicycle_path -from {emu|cpu_wrapper|cpu_inst_p|core|*} -to {emu|cpu_wrapper|cpu_inst_p|mmu|*}  -hold 3
set_multicycle_path -from {emu|cpu_wrapper|cpu_inst_p|mmu|*}  -to {emu|cpu_wrapper|cpu_inst_p|core|*} -setup 4
set_multicycle_path -from {emu|cpu_wrapper|cpu_inst_p|mmu|*}  -to {emu|cpu_wrapper|cpu_inst_p|core|*} -hold 3

# Two crossings INTO the tick-gated hierarchy from sources that are held
# levels, both taken from report_timing on the first FAST_CLOCK fit
# (fd9a8220, divide 2) and unchanged by the divide:
#
#   cpu_wrapper|bus_timeout|berr -> core|epf_*   -13.1 ns single-cycle.  cpu_wrapper's
#     ap040_bus_timeout HOLDS berr until the bus adapter has sampled it on a
#     qualified edge and released cpu_req (its own header); the core only
#     samples it on core_tick.  A level that persists across ticks into a
#     register that only updates on ticks has four cycles.
#   core|mem_addr -> cache|r_*        -7.0 ns single-cycle.  mem_addr is
#     core-driven and holds for the whole request; the cache's r_row/r_tag/
#     r_word/r_way/r_bank/r_beat/r_addr/r_size/r_off are its ce-gated capture
#     registers (ap040_cache.v: written only under ce on acceptance).  The
#     pattern is r_* ON PURPOSE: it must not reach the tag/data RAM ports,
#     which sample every fast cycle and were left single-cycle above.
set_multicycle_path -from {emu|cpu_wrapper|bus_timeout|*} -to {emu|cpu_wrapper|cpu_inst_p|core|*} -setup 4
set_multicycle_path -from {emu|cpu_wrapper|bus_timeout|*} -to {emu|cpu_wrapper|cpu_inst_p|core|*} -hold 3
set_multicycle_path -from {emu|cpu_wrapper|cpu_inst_p|core|*} -to {emu|cpu_wrapper|cpu_inst_p|g_cache.cache|r_*} -setup 4
set_multicycle_path -from {emu|cpu_wrapper|cpu_inst_p|core|*} -to {emu|cpu_wrapper|cpu_inst_p|g_cache.cache|r_*} -hold 3

# The divide-4 fit (4910e5c8) closed the address cone and left one class in
# its worst 60: cpu_inst_p|core_stall_watchdog|berr -> core|epf_*, -12.3 ns.
# A SECOND ap040_bus_timeout instance -- the core-stall watchdog inside
# ap040_tg68k_compat -- with the same held berr into the same tick-gated
# fetch-queue registers as the wrapper's bus_timeout above.  Same
# derivation, same four cycles.
set_multicycle_path -from {emu|cpu_wrapper|cpu_inst_p|core_stall_watchdog|*} -to {emu|cpu_wrapper|cpu_inst_p|core|*} -setup 4
set_multicycle_path -from {emu|cpu_wrapper|cpu_inst_p|core_stall_watchdog|*} -to {emu|cpu_wrapper|cpu_inst_p|core|*} -hold 3

# Below the watchdog, the divide-4 fit's remaining crossings (report_timing,
# 4910e5c8), each with the reason it has four cycles:
#
#   bus16 <-> core   -9.1 / -5.5 ns.  ap040_bus16_adapter's contract (its
#     header): "all outputs are registered and change only on clkena_in
#     edges" -- the adapter is tick-gated like the core.  Both ends update
#     only on core_tick, in both directions.
#   cache|ack_r -> core   -8.9 ns.  ack_r is written only inside the cache
#     FSM, which runs under ce (.ce(clkena_in)); tick-to-tick.
#   cache|ctag_ram -> cache|ci_inv_row   -3.8 ns.  The tag row's port-A
#     write enable is ce & tag_we, so the RAM's we_reg and its address only
#     move on ticks; the endpoint is written under ce.  Scoped to the one
#     reported endpoint on purpose -- the cache also holds FREE-RUNNING
#     registers (look_snooped, fill_snooped: set on any clock so a snoop
#     cannot be missed while ce is low) and no exception may reach those.
#
# core|mem_addr -> cache|look_snooped, -5.9 ns: relaxed AFTER an RTL change,
# and with its standing stated exactly.  The lookup guard is now two terms
# (ap040_cache.v): the compare-cycle term reads the CAPTURED row (r_row,
# ce-gated), so the window that matters no longer touches this path at
# all; only the acceptance-cycle term still reads the live translation.
# Under a divided enable that term's exposure is the one fast cycle after
# a tick while the cone settles -- and a snoop landing there writes the tag
# row before the lookup's read is issued on the tick, so the read misses
# by itself.  PROVEN, by a control that fails in the other regime:
# tb_ap040_cache_snoop under the silicon-faithful tag-row model
# (-DSNOOP_MIXED_X) with +inj_acc_whole -- the acceptance term blind for
# the WHOLE acceptance wait, not just the settle cycle -- FAILS at CE_DIV 1
# (the compare is the next cycle and sees the collision's garbage) and
# PASSES at CE_DIV 4 (the row is re-read every cycle and cleaned before the
# compare four cycles on).  The term may be arbitrarily late under the
# divided enable; four cycles is well inside "arbitrarily".  The compare
# term, which this path does not reach, is the one that is load-bearing at
# divide 4, and its own control (+inj_look_whole) fails there.
set_multicycle_path -from {emu|cpu_wrapper|cpu_inst_p|core|*} -to {emu|cpu_wrapper|cpu_inst_p|g_cache.cache|look_snooped*} -setup 4
set_multicycle_path -from {emu|cpu_wrapper|cpu_inst_p|core|*} -to {emu|cpu_wrapper|cpu_inst_p|g_cache.cache|look_snooped*} -hold 3
set_multicycle_path -from {emu|cpu_wrapper|cpu_inst_p|bus16|*} -to {emu|cpu_wrapper|cpu_inst_p|core|*}  -setup 4
set_multicycle_path -from {emu|cpu_wrapper|cpu_inst_p|bus16|*} -to {emu|cpu_wrapper|cpu_inst_p|core|*}  -hold 3
set_multicycle_path -from {emu|cpu_wrapper|cpu_inst_p|core|*}  -to {emu|cpu_wrapper|cpu_inst_p|bus16|*} -setup 4
set_multicycle_path -from {emu|cpu_wrapper|cpu_inst_p|core|*}  -to {emu|cpu_wrapper|cpu_inst_p|bus16|*} -hold 3
set_multicycle_path -from {emu|cpu_wrapper|cpu_inst_p|g_cache.cache|ack_r*} -to {emu|cpu_wrapper|cpu_inst_p|core|*} -setup 4
set_multicycle_path -from {emu|cpu_wrapper|cpu_inst_p|g_cache.cache|ack_r*} -to {emu|cpu_wrapper|cpu_inst_p|core|*} -hold 3
set_multicycle_path -from {emu|cpu_wrapper|cpu_inst_p|g_cache.cache|ctag_ram|*} -to {emu|cpu_wrapper|cpu_inst_p|g_cache.cache|ci_inv_row*} -setup 4
set_multicycle_path -from {emu|cpu_wrapper|cpu_inst_p|g_cache.cache|ctag_ram|*} -to {emu|cpu_wrapper|cpu_inst_p|g_cache.cache|ci_inv_row*} -hold 3

# Round 3 (80c30bef) residual, -7.0 ns: mmu|atc_ram -> cache|r_tag/r_row/
# r_addr.  The ATC's registered output feeds the translation mux and lands
# on the cache's ce-gated capture registers; its address comes from the
# tick-gated core, so the output moves only after a tick.  Same derivation
# as core -> cache|r_* above, same scope: the r_* captures only.
set_multicycle_path -from {emu|cpu_wrapper|cpu_inst_p|mmu|*} -to {emu|cpu_wrapper|cpu_inst_p|g_cache.cache|r_*} -setup 4
set_multicycle_path -from {emu|cpu_wrapper|cpu_inst_p|mmu|*} -to {emu|cpu_wrapper|cpu_inst_p|g_cache.cache|r_*} -hold 3

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
