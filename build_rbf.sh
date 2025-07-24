#!/bin/bash

echo "=== Building Minimig RBF with FPU Support ==="
echo

# Check if SOF file exists
if [ ! -f "output_files/Minimig.sof" ]; then
    echo "Error: SOF file not found. Please run compilation first."
    exit 1
fi

# Get SOF file timestamp
SOF_TIME=$(stat -c %y output_files/Minimig.sof | cut -d. -f1)
echo "SOF file timestamp: $SOF_TIME"

# Convert SOF to RBF
echo "Converting SOF to RBF..."
quartus_cpf -c output_files/Minimig.sof Minimig.rbf

if [ $? -eq 0 ]; then
    echo "✓ RBF file created successfully!"
    ls -lah Minimig.rbf
    
    # Add build info
    echo
    echo "FPU Build Information:"
    echo "- CPU Mode: 68020"
    echo "- FPU: MC68881/68882 compatible"
    echo "- FPU Enabled by default"
    echo "- IEEE 754 compliant"
    echo "- 8 x 80-bit FP registers"
    echo
    echo "To use this core:"
    echo "1. Copy Minimig.rbf to your MiSTer SD card /media/fat/"
    echo "2. The FPU is enabled by default"
    echo "3. Software compiled with -m68881 will use hardware FPU"
else
    echo "✗ Error creating RBF file"
    exit 1
fi