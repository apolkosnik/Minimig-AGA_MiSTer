#!/usr/bin/tclsh
# TCL script to run register test

# Compile the PMMU module
vcom -93 -work work ../../rtl/tg68k/TG68K_PMMU_030.vhd

# Compile the test
vcom -93 -work work tb_reg_test.vhd

# Start simulation
vsim -t 1ps -L work tb_reg_test

# Run the simulation
run -all