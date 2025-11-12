#!/bin/bash
#============================================================================
# Simulation Script for TG68K030_Bus_Adapter
#
# Requires: Icarus Verilog (iverilog)
# Install on Ubuntu/Debian: sudo apt-get install iverilog
# Install on macOS: brew install icarus-verilog
#
# Usage: ./run_bus_adapter_sim.sh
#============================================================================

set -e  # Exit on error

echo "========================================================================"
echo "TG68K030_Bus_Adapter Simulation"
echo "========================================================================"

# Check if iverilog is installed
if ! command -v iverilog &> /dev/null; then
    echo "ERROR: iverilog not found!"
    echo "Please install Icarus Verilog:"
    echo "  Ubuntu/Debian: sudo apt-get install iverilog"
    echo "  macOS: brew install icarus-verilog"
    exit 1
fi

# Clean previous build
echo "Cleaning previous build..."
rm -f bus_adapter_sim
rm -f TG68K030_Bus_Adapter_tb.vcd

# Compile
echo "Compiling..."
iverilog -o bus_adapter_sim \
    -g2012 \
    -Wall \
    TG68K030_Bus_Adapter.v \
    TG68K030_Bus_Adapter_tb.v

if [ $? -ne 0 ]; then
    echo "ERROR: Compilation failed!"
    exit 1
fi

echo "Compilation successful!"
echo ""

# Run simulation
echo "Running simulation..."
echo ""
./bus_adapter_sim

if [ $? -eq 0 ]; then
    echo ""
    echo "========================================================================"
    echo "Simulation completed successfully!"
    echo ""
    echo "Waveform saved to: TG68K030_Bus_Adapter_tb.vcd"
    echo "View with: gtkwave TG68K030_Bus_Adapter_tb.vcd"
    echo "========================================================================"
else
    echo ""
    echo "========================================================================"
    echo "ERROR: Simulation failed!"
    echo "========================================================================"
    exit 1
fi
