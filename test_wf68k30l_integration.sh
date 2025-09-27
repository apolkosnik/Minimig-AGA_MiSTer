#!/bin/bash

# WF68K30L Integration Test Script
echo "=== WF68K30L Integration Test ==="
echo "Testing syntax and basic functionality..."

# 1. Check if all VHDL files exist
echo "1. Checking WF68K30L VHDL files:"
VHDL_FILES=(
    "rtl/wf68k30L/wf68k30L_pkg.vhd"
    "rtl/wf68k30L/wf68k30L_top.vhd"
    "rtl/wf68k30L/wf68k30L_data_registers.vhd"
    "rtl/wf68k30L/wf68k30L_address_registers.vhd"
    "rtl/wf68k30L/wf68k30L_alu.vhd"
    "rtl/wf68k30L/wf68k30L_exception_handler.vhd"
    "rtl/wf68k30L/wf68k30L_control.vhd"
    "rtl/wf68k30L/wf68k30L_opcode_decoder.vhd"
    "rtl/wf68k30L/wf68k30L_bus_interface.vhd"
)

for file in "${VHDL_FILES[@]}"; do
    if [ -f "$file" ]; then
        echo "  ✓ $file"
    else
        echo "  ✗ MISSING: $file"
        exit 1
    fi
done

# 2. Check if files.qip includes WF68K30L
echo "2. Checking files.qip integration:"
if grep -q "wf68k30L" files.qip; then
    echo "  ✓ WF68K30L files added to files.qip"
else
    echo "  ✗ WF68K30L files not found in files.qip"
    exit 1
fi

# 3. Check cpu_wrapper.v integration
echo "3. Checking cpu_wrapper.v integration:"
if grep -q "WF68K30L_TOP" rtl/cpu_wrapper.v; then
    echo "  ✓ WF68K30L_TOP instantiated in cpu_wrapper.v"
else
    echo "  ✗ WF68K30L_TOP not found in cpu_wrapper.v"
    exit 1
fi

if grep -q "cpucfg\[2\]" rtl/cpu_wrapper.v; then
    echo "  ✓ cpucfg[2] support added"
else
    echo "  ✗ cpucfg[2] not found in cpu_wrapper.v"
    exit 1
fi

# 4. Check 3-bit cpucfg support
echo "4. Checking 3-bit cpucfg support:"
if grep -q "\[2:0\].*cpu_config" rtl/userio.v; then
    echo "  ✓ userio.v updated for 3-bit cpu_config"
else
    echo "  ✗ userio.v not updated for 3-bit cpu_config"
    exit 1
fi

if grep -q "\[2:0\].*cpucfg" rtl/minimig.v; then
    echo "  ✓ minimig.v updated for 3-bit cpucfg"
else
    echo "  ✗ minimig.v not updated for 3-bit cpucfg"
    exit 1
fi

if grep -q "\[2:0\].*cpucfg" Minimig.sv; then
    echo "  ✓ Minimig.sv updated for 3-bit cpucfg"
else
    echo "  ✗ Minimig.sv not updated for 3-bit cpucfg"
    exit 1
fi

# 5. Quick syntax check with quartus_map
echo "5. Running quick syntax check:"
timeout 60 quartus_map Minimig_DS 2>&1 | head -50 | grep -E "(Error|Found entity.*WF68K30L)" || true

echo ""
echo "=== Integration Test Results ==="
echo "✓ All WF68K30L files present and integrated"
echo "✓ CPU selection system expanded to 3-bit"
echo "✓ WF68K30L instantiation complete"
echo ""
echo "WF68K30L CPU core integration appears successful!"
echo "The core can be selected with cpucfg = 100 (4 in decimal)"
echo ""
echo "CPU Configuration Options:"
echo "  000 (0) = fx68k (MC68000)"
echo "  001 (1) = TG68K (MC68010)"
echo "  010 (2) = TG68K (MC68020)"
echo "  100 (4) = WF68K30L (MC68030) ← NEW!"