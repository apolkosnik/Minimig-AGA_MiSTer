#!/bin/bash

# Minimig 32-bit Build Automation Script
# Automates the build process for the 32-bit wide bus implementation

set -e  # Exit on any error

# Configuration
PROJECT_NAME="Minimig"
BUILD_DIR="output_files"
QUARTUS_BIN="/opt/intelFPGA/17.0/quartus/bin"  # Adjust path as needed
LOG_FILE="build_32bit.log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
    exit 1
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" | tee -a "$LOG_FILE"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a "$LOG_FILE"
}

# Check prerequisites
check_prerequisites() {
    log "Checking prerequisites..."
    
    # Check if Quartus is available
    if ! command -v quartus_sh &> /dev/null; then
        if [ -f "$QUARTUS_BIN/quartus_sh" ]; then
            export PATH="$QUARTUS_BIN:$PATH"
            log "Added Quartus to PATH: $QUARTUS_BIN"
        else
            error "Quartus not found. Please install Quartus Prime or update QUARTUS_BIN path."
        fi
    fi
    
    # Check if project files exist
    if [ ! -f "${PROJECT_NAME}.qpf" ]; then
        error "Project file ${PROJECT_NAME}.qpf not found!"
    fi
    
    if [ ! -f "${PROJECT_NAME}.qsf" ]; then
        error "Settings file ${PROJECT_NAME}.qsf not found!"
    fi
    
    success "Prerequisites check passed"
}

# Validate 32-bit implementation
validate_implementation() {
    log "Validating 32-bit implementation..."
    
    # Run our test scripts
    if [ -f "test_32bit_compatibility.py" ]; then
        log "Running 32-bit compatibility test..."
        python3 test_32bit_compatibility.py || error "32-bit compatibility test failed"
    fi
    
    if [ -f "test_comprehensive.py" ]; then
        log "Running comprehensive test suite..."
        python3 test_comprehensive.py || error "Comprehensive test failed"
    fi
    
    # Check for dual SDRAM configuration
    if grep -q "MISTER_DUAL_SDRAM=1" sys/sys_dual_sdram.tcl; then
        success "DUAL_SDRAM configuration verified"
    else
        error "DUAL_SDRAM not properly configured"
    fi
    
    success "Implementation validation passed"
}

# Clean previous builds
clean_build() {
    log "Cleaning previous build artifacts..."
    
    if [ -d "$BUILD_DIR" ]; then
        rm -rf "$BUILD_DIR"
        log "Removed previous build directory"
    fi
    
    # Clean Quartus temporary files
    rm -f *.rpt *.summary *.pin *.done *.jdi *.qpgm *.qws
    rm -f db/*.* incremental_db/*.* simulation/*.*
    rm -rf db incremental_db simulation 2>/dev/null || true
    
    success "Build environment cleaned"
}

# Setup build environment
setup_build() {
    log "Setting up build environment for 32-bit configuration..."
    
    # Create build directory
    mkdir -p "$BUILD_DIR"
    
    # Verify dual SDRAM is enabled
    if ! quartus_sh --tcl_eval "project_open ${PROJECT_NAME}; source sys/sys_dual_sdram.tcl; project_close" &>> "$LOG_FILE"; then
        error "Failed to apply dual SDRAM configuration"
    fi
    
    success "Build environment configured"
}

# Run synthesis
run_synthesis() {
    log "Running synthesis for 32-bit Minimig..."
    
    if ! quartus_map "$PROJECT_NAME" &>> "$LOG_FILE"; then
        error "Synthesis failed! Check $LOG_FILE for details."
    fi
    
    success "Synthesis completed successfully"
}

# Run fitting
run_fitting() {
    log "Running place and route..."
    
    if ! quartus_fit "$PROJECT_NAME" &>> "$LOG_FILE"; then
        error "Place and route failed! Check $LOG_FILE for details."
    fi
    
    success "Place and route completed successfully"
}

# Run timing analysis
run_timing() {
    log "Running timing analysis..."
    
    if ! quartus_sta "$PROJECT_NAME" &>> "$LOG_FILE"; then
        warning "Timing analysis completed with warnings. Check $LOG_FILE for details."
    else
        success "Timing analysis passed"
    fi
}

# Generate programming files
generate_files() {
    log "Generating programming files..."
    
    if ! quartus_asm "$PROJECT_NAME" &>> "$LOG_FILE"; then
        error "Assembly failed! Check $LOG_FILE for details."
    fi
    
    # Check if RBF file was generated
    if [ -f "${BUILD_DIR}/${PROJECT_NAME}.rbf" ]; then
        success "RBF file generated: ${BUILD_DIR}/${PROJECT_NAME}.rbf"
    else
        error "RBF file not generated!"
    fi
}

# Post-build validation
post_build_check() {
    log "Performing post-build validation..."
    
    # Check resource utilization
    if [ -f "${BUILD_DIR}/${PROJECT_NAME}.fit.rpt" ]; then
        local logic_util=$(grep -A 5 "Logic utilization" "${BUILD_DIR}/${PROJECT_NAME}.fit.rpt" | grep "%" | head -1 | awk '{print $4}' | tr -d '%' 2>/dev/null || echo "N/A")
        log "Logic utilization: ${logic_util}%"
        
        if [ "$logic_util" != "N/A" ] && [ "$logic_util" -gt 90 ]; then
            warning "High logic utilization: ${logic_util}%. Consider optimization."
        fi
    fi
    
    # Check timing
    if [ -f "${BUILD_DIR}/${PROJECT_NAME}.sta.rpt" ]; then
        if grep -q "Timing requirements not met" "${BUILD_DIR}/${PROJECT_NAME}.sta.rpt"; then
            warning "Timing requirements not met. Check timing report."
        else
            success "All timing requirements met"
        fi
    fi
    
    success "Post-build validation completed"
}

# Main build process
main() {
    echo "=========================================="
    echo "Minimig 32-bit Wide Bus Build Script"
    echo "=========================================="
    echo ""
    
    # Initialize log
    echo "Build started at $(date)" > "$LOG_FILE"
    
    # Execute build steps
    check_prerequisites
    validate_implementation
    clean_build
    setup_build
    run_synthesis
    run_fitting
    run_timing
    generate_files
    post_build_check
    
    echo ""
    echo "=========================================="
    success "32-bit Minimig build completed successfully!"
    echo "=========================================="
    echo ""
    echo "Generated files:"
    echo "  - RBF: ${BUILD_DIR}/${PROJECT_NAME}.rbf"
    echo "  - SOF: ${BUILD_DIR}/${PROJECT_NAME}.sof"
    echo "  - Log: $LOG_FILE"
    echo ""
    echo "Next steps:"
    echo "  1. Copy ${PROJECT_NAME}.rbf to your MiSTer SD card"
    echo "  2. Test the 32-bit implementation"
    echo "  3. Monitor performance with the bus monitor"
    echo ""
}

# Handle command line arguments
case "${1:-}" in
    "clean")
        clean_build
        ;;
    "validate")
        validate_implementation
        ;;
    "")
        main
        ;;
    *)
        echo "Usage: $0 [clean|validate]"
        echo "  clean    - Clean build artifacts only"
        echo "  validate - Run validation tests only"
        echo "  (no args) - Full build process"
        exit 1
        ;;
esac