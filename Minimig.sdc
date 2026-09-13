derive_pll_clocks
derive_clock_uncertainty

# P2 / FAST_CLOCK: the CPU is on clk_114 with a 4:1 core enable (Minimig.sv,
# cpu_wrapper CORE_DIV=4).  The exceptions below are written per REGISTER
# CLASS, not per module: a netlist census on the 60a42def fit (report_timing
# from core_phase to every ena pin under cpu_inst_p) found 8022 registers
# whose enable is core_enable, 203 whose enable is folded into D (one-hot
# FSMs, ce-gated RAM write strobes) -- both change only at a tick -- and
# 1321 that core_enable never reaches: every RAM port register, the MMU's
# one-clock lookup pipe, the cache snoop flags, the core's IPL/IRQ chain
# (since put under ce -- ipl_s2 -> exc_addr was a 29.5 ns cone read at
# ticks), the walker-write snoop pipe and the watchdog.  Module-wide sets
# had put most of those on both sides of a four-cycle exception.  The
# census is re-run on every fit by tests/ap040/sta/sta_precheck.tcl: a
# free-running register inside TICK, or a RAM-to-RAM chain outside the
# write ports below, fails the check before the gate is trusted.
#
# Let T be a tick edge.  A tick-gated register (TICK) launches at T and its
# tick-gated consumer captures at T+4: four cycles.  A free-running register
# whose input is tick-launched (RAMP: RAM port registers; PIPE: the MMU
# lookup pipe) re-samples every edge and holds the new value from T+1; its
# input path is single-cycle (no exception: it must be right by T+1) and it
# launches at T+1, so it gets THREE cycles to a tick-gated consumer, not
# four.  A register that can change at ANY edge (ASYN: snoop flags, IPL
# synchronisers and the IRQ-hold state, the walker-write snoop pipe) gets
# no exception in either direction -- an IRQ level torn at a tick is a
# spurious interrupt, and the flags' compare-cycle terms carry the snoop
# proof (ap040_cache.v).  Free-running chains (FR1 -> FR1) would shorten
# the budget again; the census script asserts there are none except the
# port-B case below.
#
# ctag_ram port B is the cache's write-only invalidation port: q_b is
# unconnected, and its strobe is snoop_wr | (ce & ...) (ap040_cache.v,
# inv_wren).  Between ticks ce is 0, so the only write there is a snoop's,
# whose address arm and select are single-cycle by construction --
# snoop_wr's tick-gated suppression term is the LIVE term only under ce and
# a registered copy otherwise (snoop_sweep_*_r).  Everything else that
# reaches port B is consumed at a tick edge: four cycles from TICK, three
# from FR1.  That is the class the round-8 gate stopped on (atc_ram and
# l_row -> ctag_ram~portb_address at -2.5 ns, core|mem_addr at -2.35).
#
# What no exception may touch: the RAM controllers' acknowledge into
# core_enable, the enable net itself (core_phase -> ena, single-cycle) and
# anything into a RAM read port.  The acceptance-cycle term into
# look_snooped from the core and MMU is relaxed on the proof recorded in
# ap040_cache.v (tb_ap040_cache_snoop +inj_acc_whole passes at CE_DIV 4);
# the cache's own terms into it are not.
# The block applies only to a P2 netlist: cpu_wrapper's FAST_CLOCK chip
# machine (g_sync_chip) exists in no other configuration, and its register
# classes would relax 35 ns single-cycle paths to four cycles on the 28 MHz
# CPU.  The else branch is the 28 MHz configuration's own CPU constraint:
# the core's registers launch at 28 MHz into the 114 MHz RAM controllers,
# whose chip-select handoff (ram_cs_guard) gives them two of those cycles.
if {[get_collection_size [get_registers -nowarn {emu|cpu_wrapper|g_sync_chip.*}]] > 0} {
    set P {emu|cpu_wrapper|cpu_inst_p}
    set ALL   [get_registers "$P|*"]
    set RAMP  [get_registers "$P|*ram_block*"]
    set PIPE  [get_registers "$P|mmu|l_row*"]
    foreach pat {mmu|l_tag* mmu|l_ld* mmu|sweep_row_q* mmu|sweep_valid_q*} {
        set PIPE [add_to_collection $PIPE [get_registers "$P|$pat"]]
    }
    # Every member pattern ends in a wildcard on purpose: the fitter may keep a
    # duplicate of any of these (wsnp_pend~DUPLICATE on the 35c0650a fit), an
    # exact-name query returns both copies, but remove_from_collection with that
    # collection drops only the original -- the copy stayed in TICK and its
    # fanout got the four-cycle relaxation while it changes every cycle.  A
    # wildcard query removes both (tests/ap040/sta/precheck.py now fails on any
    # register that sits in two sets).
    set ASYN  [get_registers "$P|g_cache.cache|look_snooped*"]
    foreach pat {g_cache.cache|fill_snooped* g_cache.cache|snoop_sweep_on_r* g_cache.cache|snoop_sweep_row_r* \
                 wsnp_addr* wsnp_pend* walker_wr_d* core_stall_watchdog|*} {
        set ASYN [add_to_collection $ASYN [get_registers "$P|$pat"]]
    }
    set FR1   [add_to_collection $RAMP $PIPE]
    set TICK  [remove_from_collection $ALL [add_to_collection $FR1 $ASYN]]
    set CTAGB [get_registers "$P|g_cache.cache|ctag_ram|*~portb_*"]
    set ATCB  [get_registers "$P|mmu|atc_ram|*~portb_*"]
    set FR1_MMU [add_to_collection [get_registers "$P|mmu|*ram_block*"] $PIPE]
    set LOOKS [get_registers "$P|g_cache.cache|look_snooped*"]
    set TICK_CM [remove_from_collection [add_to_collection [get_registers "$P|core|*"] [get_registers "$P|mmu|*"]] [add_to_collection $FR1 $ASYN]]
    set WDOG  [get_registers "$P|core_stall_watchdog|*"]
    set WTMO  [get_registers {emu|cpu_wrapper|bus_timeout|*}]
    foreach {from to s h} [list \
        TICK    TICK  4 3 \
        FR1     TICK  3 2 \
        TICK    CTAGB 4 3 \
        FR1     CTAGB 3 2 \
        TICK    ATCB  4 3 \
        FR1     ATCB  3 2 \
        FR1_MMU LOOKS 3 2 \
        TICK_CM LOOKS 4 3 \
        WDOG    TICK  4 3 \
        WTMO    TICK  4 3 ] {
        set_multicycle_path -from [set $from] -to [set $to] -setup $s
        set_multicycle_path -from [set $from] -to [set $to] -hold  $h
    }

    # cpu_wrapper|cache_inhibit_r: the request-side copy of the MMU's cache-mode
    # bit, single-cycle like its siblings -- but its cone is the whole ATC lookup
    # (mem_addr -> lk_fresh -> hit -> atc_fault -> cache_inhibit, 7.9 ns) and it
    # missed by 12 ps on the 3edd9a98 fit while ramaddr_r/ramsel_r keep +1.9 ns.
    # Its ONE consumer is cpu_cache_new's FILL1 allocation decision (all three
    # controllers; ddram_ctrl ORs ramshared in), reached only through RDTAG and
    # READ: with chip-select asserted from the request registers at T+1, the
    # controller first reads cache_inhibit at T+5 (T+4 with READ_PIPE 0).  Two
    # cycles from every CPU register -- tick-gated (launch T, right by T+2) or
    # RAM port / MMU pipe (launch T+1, right by T+3) -- leaves that untouched.
    # tests/ap040/sta reports the class as cpu_ci.
    set CI [get_registers {emu|cpu_wrapper|cache_inhibit_r}]
    set_multicycle_path -from $ALL -to $CI -setup 2
    set_multicycle_path -from $ALL -to $CI -hold  1
} else {
    set_multicycle_path -from {emu|cpu_wrapper|cpu_inst*} -to {emu|ram*} -setup 2
    set_multicycle_path -from {emu|cpu_wrapper|cpu_inst*} -to {emu|ram*} -hold 1
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

# yc_out: no exception.  The chroma sine lookups are registered a stage ahead
# of the DSP multiply in sys/yc_out.sv (chroma_sin_r/cos_r/burst_r); the old
# chroma_LUT_BURST -> phase[*].u multicycle covered a DDS reference that
# advances every clk_114 cycle and would have been false -- its sources no
# longer exist.  On the 0db34c9c fit the SIN/COS paths were the whole clk_114
# residue at -1.0 ns; a register, not an exception, is what closes them.

# emu PLL cross-clock: counter[1]→counter[0] marginal path
set_multicycle_path -setup 2 -from [get_clocks "emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter\[1\].output_counter|divclk"] -to [get_clocks "emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter\[0\].output_counter|divclk"]
set_multicycle_path -hold 1 -from [get_clocks "emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter\[1\].output_counter|divclk"] -to [get_clocks "emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter\[0\].output_counter|divclk"]

#these constraints aren't really correct, but help fitting.
#28MHz pixel clock might be affected when scandoubler fx is used.
set_multicycle_path -to {*Hq2x*} -setup 2
set_multicycle_path -to {*Hq2x*} -hold 1
set_multicycle_path -from [get_clocks { *|pll|pll_inst|altera_pll_i|*[0].*|divclk}] -to {ascal|*} -setup 2
set_multicycle_path -from [get_clocks { *|pll|pll_inst|altera_pll_i|*[0].*|divclk}] -to {ascal|*} -hold 1
