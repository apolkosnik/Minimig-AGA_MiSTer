# Makefile for TG68K 68030 Test Suite
# Provides easy commands to run comprehensive tests

# Paths
MODELSIM_PATH = /opt/intelFPGA_lite/17.0/modelsim_ase
VSIM = $(MODELSIM_PATH)/linuxaloem/vsim
VCOM = $(MODELSIM_PATH)/linuxaloem/vcom
VLIB = $(MODELSIM_PATH)/linuxaloem/vlib

PROJECT_ROOT = /home/adam/68030/Minimig-AGA_MiSTer
TEST_DIR = $(PROJECT_ROOT)/tests/tg68k_030
RTL_DIR = $(PROJECT_ROOT)/rtl/tg68k

# Test targets
.PHONY: all clean test-pmmu test-cache test-cacr test-integration test-diagrom test-advanced test-fault test-stress setup help

# Default target
all: test-comprehensive

# Help target
help:
	@echo "TG68K 68030 Enhanced Test Suite"
	@echo "==============================="
	@echo ""
	@echo "Available targets:"
	@echo "  all              - Run comprehensive test suite"
	@echo "  setup            - Setup ModelSim environment"
	@echo "  test-pmmu        - Test basic PMMU component"
	@echo "  test-cache       - Test Cache component only"  
	@echo "  test-cacr        - Test CACR register only"
	@echo "  test-integration - Test full system integration"
	@echo "  test-diagrom     - Test DiagROM boot sequence"
	@echo "  test-advanced    - Run advanced PMMU functionality tests"
	@echo "  test-fault       - Run comprehensive fault handling tests"
	@echo "  test-stress      - Run page walker stress tests"
	@echo "  test-all         - Run original test suite"
	@echo "  test-comprehensive - Run ALL enhanced tests"
	@echo "  clean            - Clean generated files"
	@echo "  syntax-check     - Check VHDL syntax only"
	@echo "  help             - Show this help"
	@echo ""
	@echo "Requirements:"
	@echo "  - ModelSim ASE installed at $(MODELSIM_PATH)"
	@echo "  - VHDL source files in $(RTL_DIR)"
	@echo ""

# Setup ModelSim environment
setup:
	@echo "Setting up ModelSim environment..."
	@cd $(TEST_DIR) && $(VLIB) work
	@echo "Work library created"

# Syntax check only (fast)
syntax-check: setup
	@echo "Checking VHDL syntax..."
	@cd $(TEST_DIR) && $(VCOM) -93 -check_synthesis $(RTL_DIR)/TG68K_Pack.vhd || echo "TG68K_Pack syntax issues"
	@cd $(TEST_DIR) && $(VCOM) -93 -check_synthesis $(RTL_DIR)/TG68K_PMMU_030.vhd || echo "PMMU syntax issues"  
	@cd $(TEST_DIR) && $(VCOM) -93 -check_synthesis $(RTL_DIR)/TG68K_Cache_030.vhd || echo "Cache syntax issues"
	@cd $(TEST_DIR) && $(VCOM) -93 -check_synthesis $(TEST_DIR)/tb_*.vhd || echo "Testbench syntax issues"
	@echo "Syntax check completed"

# Compile sources
compile: setup
	@echo "Compiling basic VHDL sources..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd || true
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Cache_030.vhd || true
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_pmmu_030.vhd || true
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_cache_030.vhd || true
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_cacr_test.vhd || true
	@echo "Basic compilation completed (errors ignored for initial testing)"

# Compile enhanced test sources
compile-advanced: setup
	@echo "Compiling enhanced comprehensive test sources..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd || true
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Cache_030.vhd || true
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_pmmu_030.vhd || true
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_cache_030.vhd || true
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_cacr_test.vhd || true
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_pmmu_advanced.vhd || true
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_mmu_fault_comprehensive.vhd || true
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_page_walker_stress.vhd || true
	@echo "Enhanced compilation completed (errors ignored for initial testing)"

# Individual tests
test-pmmu: compile
	@echo "Running basic PMMU tests..."
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 50us; quit" tb_pmmu_030

test-cache: compile
	@echo "Running Cache tests..."
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 30us; quit" tb_cache_030

test-cacr: compile
	@echo "Running CACR tests..."
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 10us; quit" tb_cacr_test

test-integration: compile
	@echo "Running Integration tests..."
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 100us; quit" tb_integration_test

test-diagrom: compile
	@echo "Running DiagROM boot simulation..."
	@cd $(TEST_DIR) && $(VSIM) -c -do "do run_diagrom_boot.tcl; run 50us; quit"

# Enhanced comprehensive tests
test-advanced: compile-advanced
	@echo "Running advanced PMMU functionality tests..."
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 200us; quit" tb_pmmu_advanced

test-fault: compile-advanced
	@echo "Running comprehensive fault handling tests..."
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 150us; quit" tb_mmu_fault_comprehensive

test-stress: compile-advanced
	@echo "Running page walker stress tests..."
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 300us; quit" tb_page_walker_stress

# Original comprehensive test suite
test-all: compile
	@echo "========================================"
	@echo "Running TG68K 68030 Basic Test Suite"
	@echo "========================================"
	@cd $(TEST_DIR) && $(VSIM) -batch -do run_tests.do
	@echo "Basic tests completed!"
	@echo ""
	@echo "Check the following files for results:"
	@ls -la $(TEST_DIR)/*.wlf 2>/dev/null || echo "No waveform files generated"

# Enhanced comprehensive test suite
test-comprehensive: compile-advanced
	@echo "=========================================================="
	@echo "Running TG68K 68030 Enhanced Comprehensive Test Suite"
	@echo "=========================================================="
	@echo "Running advanced PMMU functionality tests..."
	@cd $(TEST_DIR) && $(VSIM) -batch -do "vsim tb_pmmu_advanced; run 200us; quit -sim"
	@echo ""
	@echo "Running comprehensive fault handling tests..."
	@cd $(TEST_DIR) && $(VSIM) -batch -do "vsim tb_mmu_fault_comprehensive; run 150us; quit -sim"
	@echo ""
	@echo "Running page walker stress tests..."
	@cd $(TEST_DIR) && $(VSIM) -batch -do "vsim tb_page_walker_stress; run 300us; quit -sim"
	@echo ""
	@echo "Running basic test suite..."
	@cd $(TEST_DIR) && $(VSIM) -batch -do run_tests.do
	@echo ""
	@echo "=========================================================="
	@echo "ALL ENHANCED COMPREHENSIVE TESTS COMPLETED!"
	@echo "=========================================================="
	@echo "Check the following files for results:"
	@ls -la $(TEST_DIR)/*.wlf 2>/dev/null || echo "No waveform files generated"

# Real validation test for actual implementation
test-real: compile
	@echo "========================================"
	@echo "Running REAL PMMU Implementation Tests"
	@echo "========================================"
	@cd $(TEST_DIR) && $(VCOM) -93 tb_pmmu_real_validation.vhd
	@cd $(TEST_DIR) && $(VSIM) -batch -do "vsim tb_pmmu_real_validation; run 100us; quit -sim"
	@echo "Real validation tests completed!"

# GUI mode for interactive debugging
test-gui: compile
	@echo "Starting ModelSim GUI..."
	@cd $(TEST_DIR) && $(VSIM) -gui -do run_tests.do &

# Quick functional test (no waveforms)
test-quick: compile
	@echo "Running quick functional tests..."
	@cd $(TEST_DIR) && $(VSIM) -batch -do "vsim tb_pmmu_030; run 10us; quit -sim; vsim tb_cache_030; run 10us; quit -sim; quit"

# Clean generated files
clean:
	@echo "Cleaning test files..."
	@cd $(TEST_DIR) && rm -rf work/ *.wlf *.vstf transcript modelsim.ini
	@echo "Clean completed"

# Check if ModelSim is available
check-modelsim:
	@if [ ! -f $(VSIM) ]; then \
		echo "ERROR: ModelSim not found at $(MODELSIM_PATH)"; \
		echo "Please install ModelSim or update MODELSIM_PATH"; \
		exit 1; \
	else \
		echo "ModelSim found at $(MODELSIM_PATH)"; \
		$(VSIM) -version; \
	fi

# Verify test environment
verify-env: check-modelsim
	@echo "Checking test environment..."
	@if [ ! -d $(RTL_DIR) ]; then echo "ERROR: RTL directory not found"; exit 1; fi
	@if [ ! -f $(RTL_DIR)/TG68K_PMMU_030.vhd ]; then echo "ERROR: PMMU source not found"; exit 1; fi
	@if [ ! -f $(RTL_DIR)/TG68K_Cache_030.vhd ]; then echo "ERROR: Cache source not found"; exit 1; fi
	@echo "Environment verification passed"

# Generate test report
report: test-all
	@echo "Generating test report..."
	@echo "TG68K 68030 Test Report" > test_report.txt
	@echo "========================" >> test_report.txt  
	@echo "Date: $(shell date)" >> test_report.txt
	@echo "" >> test_report.txt
	@echo "Files tested:" >> test_report.txt
	@ls -la $(RTL_DIR)/TG68K_*030*.vhd >> test_report.txt
	@echo "" >> test_report.txt
	@echo "Test results in waveform files:" >> test_report.txt
	@ls -la *.wlf 2>/dev/null >> test_report.txt || echo "No waveforms generated" >> test_report.txt
	@echo "Test report generated: test_report.txt"
