derive_pll_clocks
derive_clock_uncertainty

set_multicycle_path -from {emu|cpu_wrapper|cpu_inst*} -to {emu|ram*} -setup 2
set_multicycle_path -from {emu|cpu_wrapper|cpu_inst*} -to {emu|ram*} -hold 1

set_multicycle_path -from {emu|amiga_clk|cck*} -to {emu|ram1|*} -setup 2
set_multicycle_path -from {emu|amiga_clk|cck*} -to {emu|ram1|*} -hold 1
set_multicycle_path -from {emu|minimig|*} -to {emu|ram1|*} -setup 2
set_multicycle_path -from {emu|minimig|*} -to {emu|ram1|*} -hold 1

set_false_path -from {emu|cpu_wrapper|z3ram_*}
set_false_path -from {emu|cpu_wrapper|z2ram_*}

# MC68030-specific timing constraints
# F-line instruction execution is multi-cycle by design
set_multicycle_path -from {emu|cpu_wrapper|cpu_inst_p|fline_*} -setup 3
set_multicycle_path -from {emu|cpu_wrapper|cpu_inst_p|fline_*} -hold 2

# MMU register access paths (accessed via PMOVE instruction)
set_multicycle_path -from {*mmu_reg*} -to {*pmove*} -setup 2
set_multicycle_path -from {*mmu_reg*} -to {*pmove*} -hold 1
set_multicycle_path -from {*pmove*} -to {*mmu_reg*} -setup 2
set_multicycle_path -from {*pmove*} -to {*mmu_reg*} -hold 1

# F-line decoder to executor paths (combinational but complex)
set_multicycle_path -from {*_decoder|*} -to {*_executor|*} -setup 2
set_multicycle_path -from {*_decoder|*} -to {*_executor|*} -hold 1

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
