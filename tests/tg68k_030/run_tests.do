# run_tests.do
# ModelSim script to run comprehensive 68030 tests

# Set up environment
set MODELSIM_PATH "/opt/intelFPGA_lite/17.0/modelsim_ase"
set SCRIPT_DIR [file dirname [file normalize [info script]]]
set PROJECT_ROOT [file normalize [file join $SCRIPT_DIR ".." ".."]]
set TEST_DIR [file normalize [file join $PROJECT_ROOT "tests" "tg68k_030"]]
set RTL_DIR [file normalize [file join $PROJECT_ROOT "rtl" "tg68k"]]

# Create work library
vlib work

# Compile TG68K package first
echo "Compiling TG68K Package..."
vcom -93 "$RTL_DIR/TG68K_Pack.vhd"

# Compile source files in dependency order
echo "Compiling PMMU module..."
vcom -93 "$RTL_DIR/TG68K_PMMU_030.vhd"

echo "Compiling Cache module..."
vcom -93 "$RTL_DIR/TG68K_Cache_030.vhd"

echo "Compiling ALU module..."
vcom -93 "$RTL_DIR/TG68K_ALU.vhd"

echo "Compiling Kernel module..."
vcom -93 "$RTL_DIR/TG68KdotC_Kernel.vhd"

echo "Compiling Top-level module..."
vcom -93 "$RTL_DIR/TG68K.vhd"

# Compile test benches
echo "Compiling test benches..."
vcom -93 "$TEST_DIR/tb_pmmu_030.vhd"
vcom -93 "$TEST_DIR/tb_cache_030.vhd"  
vcom -93 "$TEST_DIR/tb_cacr_test.vhd"
vcom -93 "$TEST_DIR/tb_integration_test.vhd"

# Function to run a test with timing
proc run_test {testbench duration description} {
    echo "========================================"
    echo "Running $description"
    echo "========================================"
    
    vsim -t ps $testbench
    
    # Add signals to wave window
    add wave -recursive /*
    
    # Run simulation
    run $duration
    
    # Save waveform only in GUI mode (batch mode doesn't support write format)
    if {![batch_mode]} {
        write format wave -window .main_pane.wave.interior.cs.body.pw.wf "$testbench.wlf"
    } else {
        echo "Batch mode: skipping waveform save for $testbench"
    }
    
    quit -sim
    echo "$description completed"
    echo ""
}

# Run individual component tests
echo "Starting TG68K 68030 Comprehensive Test Suite"
echo "=============================================="

# Test 1: PMMU Tests
run_test "tb_pmmu_030" "50us" "PMMU Component Tests"

# Test 2: Cache Tests  
run_test "tb_cache_030" "30us" "Cache Component Tests"

# Test 3: CACR Register Tests
run_test "tb_cacr_test" "10us" "CACR Register Tests"

# Test 4: Integration Tests
run_test "tb_integration_test" "100us" "System Integration Tests"

echo "========================================"
echo "All tests completed!"
echo "Check individual .wlf files for waveforms"
echo "========================================"

# Final summary
echo "Test Summary:"
echo "- PMMU Tests: tb_pmmu_030.wlf"
echo "- Cache Tests: tb_cache_030.wlf" 
echo "- CACR Tests: tb_cacr_test.wlf"
echo "- Integration Tests: tb_integration_test.wlf"

quit
