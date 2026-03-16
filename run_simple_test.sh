#!/bin/bash

echo "Running Simple Ethernet Test..."

# Create work directory
if [ ! -d "work" ]; then
    vlib work
fi

# Compile required modules
echo "Compiling ethernet module..."
vlog rtl/ethernet.v
if [ $? -ne 0 ]; then
    echo "Failed to compile ethernet.v"
    exit 1
fi

echo "Compiling test..."
vlog tb_simple_eth_test.v
if [ $? -ne 0 ]; then
    echo "Failed to compile testbench"
    exit 1
fi

# Run simulation
echo "Running simulation..."
vsim -c -do "run -all; quit" tb_simple_eth_test

echo "Test complete. Check output above for results."