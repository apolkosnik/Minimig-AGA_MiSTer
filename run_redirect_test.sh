#!/bin/bash

echo "Running Register Redirection Test..."

# Create work directory
if [ ! -d "work" ]; then
    vlib work
fi

# Compile required modules
echo "Compiling modules..."
vlog rtl/cpu_wrapper.v
vlog rtl/ethernet.v  
vlog tb_register_redirect_test.v

# Run simulation
echo "Running simulation..."
vsim -c -do "run -all; quit" tb_register_redirect_test

echo "Test complete. Check transcript for results."