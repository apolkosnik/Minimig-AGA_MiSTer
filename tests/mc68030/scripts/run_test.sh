#!/bin/bash
################################################################################
# MC68030 Test Execution Script
#
# This script runs a compiled VHDL testbench
# Usage: ./run_test.sh <testbench_name> [options]
################################################################################

set -e  # Exit on error

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(dirname "$SCRIPT_DIR")"
WORK_DIR="$TEST_DIR/work"
RESULTS_DIR="$TEST_DIR/results"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if GHDL is installed
if ! command -v ghdl &> /dev/null; then
    echo -e "${RED}Error: GHDL not found. Please install GHDL.${NC}"
    exit 1
fi

# Create results directory if it doesn't exist
mkdir -p "$RESULTS_DIR"

# Parse arguments
if [ $# -lt 1 ]; then
    echo "Usage: $0 <testbench_name> [--wave] [--stop-time=<time>]"
    echo "Example: $0 test_mmu_registers_tb --wave --stop-time=1ms"
    exit 1
fi

TESTBENCH_NAME="$1"
shift

# Default options
WAVE_OPTION=""
STOP_TIME="--stop-time=10ms"
VCD_FILE="$RESULTS_DIR/${TESTBENCH_NAME}.vcd"

# Parse additional options
while [[ $# -gt 0 ]]; do
    case $1 in
        --wave)
            WAVE_OPTION="--vcd=$VCD_FILE"
            shift
            ;;
        --stop-time=*)
            STOP_TIME="$1"
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Check if testbench is compiled
if [ ! -f "$WORK_DIR/${TESTBENCH_NAME}" ] && [ ! -f "$WORK_DIR/work-obj93.cf" ]; then
    echo -e "${YELLOW}Testbench not compiled. Compile it first with compile_test.sh${NC}"
    exit 1
fi

echo -e "${GREEN}Running test: $TESTBENCH_NAME${NC}"

# Run the simulation
LOG_FILE="$RESULTS_DIR/${TESTBENCH_NAME}_log.txt"

if ghdl -r --workdir="$WORK_DIR" "$TESTBENCH_NAME" $WAVE_OPTION $STOP_TIME 2>&1 | tee "$LOG_FILE"; then
    # Check if test passed
    if grep -q "ALL TESTS PASSED" "$LOG_FILE"; then
        echo -e "${GREEN}==================================${NC}"
        echo -e "${GREEN}TEST PASSED: $TESTBENCH_NAME${NC}"
        echo -e "${GREEN}==================================${NC}"
        EXIT_CODE=0
    elif grep -q "SOME TESTS FAILED" "$LOG_FILE"; then
        echo -e "${RED}==================================${NC}"
        echo -e "${RED}TEST FAILED: $TESTBENCH_NAME${NC}"
        echo -e "${RED}==================================${NC}"
        EXIT_CODE=1
    else
        echo -e "${YELLOW}==================================${NC}"
        echo -e "${YELLOW}TEST COMPLETED (status unknown)${NC}"
        echo -e "${YELLOW}==================================${NC}"
        EXIT_CODE=0
    fi
else
    echo -e "${RED}==================================${NC}"
    echo -e "${RED}TEST CRASHED: $TESTBENCH_NAME${NC}"
    echo -e "${RED}==================================${NC}"
    EXIT_CODE=2
fi

echo "Log file: $LOG_FILE"

if [ -n "$WAVE_OPTION" ]; then
    echo "Waveform file: $VCD_FILE"
    echo "View with: gtkwave $VCD_FILE"
fi

exit $EXIT_CODE
