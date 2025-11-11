#!/bin/bash
################################################################################
# MC68030 Test Compilation Script
#
# This script compiles VHDL testbenches using GHDL
# Usage: ./compile_test.sh <testbench_name>
################################################################################

set -e  # Exit on error

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(dirname "$SCRIPT_DIR")"
RTL_DIR="$TEST_DIR/../../rtl"
WORK_DIR="$TEST_DIR/work"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if GHDL is installed
if ! command -v ghdl &> /dev/null; then
    echo -e "${RED}Error: GHDL not found. Please install GHDL.${NC}"
    echo "On Ubuntu/Debian: sudo apt-get install ghdl"
    exit 1
fi

# Create work directory if it doesn't exist
mkdir -p "$WORK_DIR"

# Parse arguments
if [ $# -lt 1 ]; then
    echo "Usage: $0 <testbench_file.vhd>"
    echo "Example: $0 test_mmu_registers.vhd"
    exit 1
fi

TESTBENCH="$1"
TESTBENCH_NAME=$(basename "$TESTBENCH" .vhd)

echo -e "${GREEN}Compiling MC68030 Test: $TESTBENCH_NAME${NC}"

# Analyze (compile) the design files
echo -e "${YELLOW}Step 1: Analyzing RTL files...${NC}"

# Compile TG68K package (if needed for MC68030)
if [ -f "$RTL_DIR/tg68k/TG68K_Pack.vhd" ]; then
    ghdl -a --workdir="$WORK_DIR" --work=work "$RTL_DIR/tg68k/TG68K_Pack.vhd" || {
        echo -e "${RED}Failed to analyze TG68K_Pack.vhd${NC}"
        exit 1
    }
fi

# Compile MC68030 package (when it exists)
if [ -f "$RTL_DIR/tg68k030/TG68K030_Pack.vhd" ]; then
    ghdl -a --workdir="$WORK_DIR" --work=work "$RTL_DIR/tg68k030/TG68K030_Pack.vhd"
fi

# Compile MC68030 modules (when they exist)
for vhdl_file in "$RTL_DIR/tg68k030"/*.vhd; do
    if [ -f "$vhdl_file" ] && [ "$vhdl_file" != "$RTL_DIR/tg68k030/TG68K030_Pack.vhd" ]; then
        echo "Analyzing $(basename $vhdl_file)..."
        ghdl -a --workdir="$WORK_DIR" --work=work "$vhdl_file" || {
            echo -e "${RED}Failed to analyze $(basename $vhdl_file)${NC}"
            exit 1
        }
    fi
done

# Analyze the testbench
echo -e "${YELLOW}Step 2: Analyzing testbench...${NC}"
ghdl -a --workdir="$WORK_DIR" --work=work "$TESTBENCH" || {
    echo -e "${RED}Failed to analyze testbench${NC}"
    exit 1
}

# Elaborate (link) the design
echo -e "${YELLOW}Step 3: Elaborating design...${NC}"
ghdl -e --workdir="$WORK_DIR" --work=work "$TESTBENCH_NAME" || {
    echo -e "${RED}Failed to elaborate design${NC}"
    exit 1
}

echo -e "${GREEN}Compilation successful!${NC}"
echo "To run the test: ghdl -r --workdir=$WORK_DIR $TESTBENCH_NAME"
