derive_pll_clocks
derive_clock_uncertainty

# Cross-clock domain: CPU/system (28MHz, counter[1]) <-> SDRAM (113MHz, counter[0])
# Both clocks come from the same PLL. All cross-domain signals use handshaking
# (ramready/chipready gating clkena_in) so data is stable for multiple destination
# clock periods before sampling.

# 28MHz -> 113MHz: Source data stable for full 28MHz period (~35ns = ~4 SDRAM cycles).
# Allow 3 SDRAM cycles for combinational routing (26.55ns).
set_multicycle_path -from [get_clocks { *|pll|pll_inst|altera_pll_i|*[1].*|divclk}] \
                    -to   [get_clocks { *|pll|pll_inst|altera_pll_i|*[0].*|divclk}] -setup 3
set_multicycle_path -from [get_clocks { *|pll|pll_inst|altera_pll_i|*[1].*|divclk}] \
                    -to   [get_clocks { *|pll|pll_inst|altera_pll_i|*[0].*|divclk}] -hold 2

# 113MHz -> 28MHz: SDRAM outputs (cpu_dat_r, write_ena, ramready) stay stable for
# 2+ CPU clock periods (cpu_ack holds until ram_cs clears on a 28MHz edge).
# Allow 2 CPU clock periods (70.4ns) for combinational routing through PMMU.
set_multicycle_path -from [get_clocks { *|pll|pll_inst|altera_pll_i|*[0].*|divclk}] \
                    -to   [get_clocks { *|pll|pll_inst|altera_pll_i|*[1].*|divclk}] -setup 2
set_multicycle_path -from [get_clocks { *|pll|pll_inst|altera_pll_i|*[0].*|divclk}] \
                    -to   [get_clocks { *|pll|pll_inst|altera_pll_i|*[1].*|divclk}] -hold 1

set_false_path -from {emu|cpu_wrapper|z3ram_*}
set_false_path -from {emu|cpu_wrapper|z2ram_*}

# ISSP debug probes: these are observability-only paths sampled by JTAG at low speed.
# Exclude from timing analysis to prevent them from affecting critical-path placement.
set_false_path -to   {emu|cpu_wrapper|stp_*}
set_false_path -from {emu|cpu_wrapper|stp_*}
set_false_path -to   {emu|cpu_wrapper|excf_*}
set_false_path -from {emu|cpu_wrapper|excf_*}
set_false_path -to   {emu|cpu_wrapper|hang_*}
set_false_path -from {emu|cpu_wrapper|hang_*}
set_false_path -to   {*|excf_issp|*}
set_false_path -to   {*|pmmu_issp|*}
set_false_path -to   {*|pmmu_issp_desc|*}
set_false_path -to   {*|cpus_issp|*}
set_false_path -to   {*|regs_issp|*}

set_false_path -from {emu|minimig|USERIO1|cpu_config*}
set_false_path -from {emu|minimig|USERIO1|ide_config*}
set_false_path -from {emu|minimig|USERIO1|bootrom}
set_false_path -from {emu|minimig|CPU1|halt}

#these constraints aren't really correct, but help fitting.
#28MHz pixel clock might be affected when scandoubler fx is used.
set_multicycle_path -to {*Hq2x*} -setup 2
set_multicycle_path -to {*Hq2x*} -hold 1
set_multicycle_path -from [get_clocks { *|pll|pll_inst|altera_pll_i|*[0].*|divclk}] -to {ascal|*} -setup 2
set_multicycle_path -from [get_clocks { *|pll|pll_inst|altera_pll_i|*[0].*|divclk}] -to {ascal|*} -hold 1
