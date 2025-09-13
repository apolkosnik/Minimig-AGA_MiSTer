#!/usr/bin/tclsh
# TCL script to run PMMU 030 testbench

# Compile the PMMU module
vcom -93 -work work ../../rtl/tg68k/TG68K_PMMU_030.vhd

# Compile the testbench
vcom -93 -work work tb_pmmu_030.vhd

# Start simulation
vsim -t 1ps -L work tb_pmmu_030

# Run the simulation
run -all