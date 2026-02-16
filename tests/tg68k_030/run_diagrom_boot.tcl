#!/usr/bin/tclsh
# TCL script to run DiagROM boot simulation
# Uses tb_pmmu_diagnostic testbench to simulate PMMU detection sequence

# Start simulation with the diagnostic testbench
vsim -t 1ps -L work tb_pmmu_diagnostic

# Run the simulation
run -all
