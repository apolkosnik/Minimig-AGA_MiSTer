#!/usr/bin/tclsh
# TCL script to run all tests

puts "=== Running All TG68K 030 Tests ==="

# Cache Tests
puts "Running Cache Tests..."
vcom -93 -work work ../../rtl/tg68k/TG68K_Cache_030.vhd
vcom -93 -work work tb_cache_030.vhd
vsim -t 1ps -L work tb_cache_030 -do "run -all; quit" -c

# PMMU Tests  
puts "Running PMMU Tests..."
vcom -93 -work work ../../rtl/tg68k/TG68K_PMMU_030.vhd
vcom -93 -work work tb_pmmu_030.vhd
vsim -t 1ps -L work tb_pmmu_030 -do "run -all; quit" -c

puts "=== All Tests Complete ==="