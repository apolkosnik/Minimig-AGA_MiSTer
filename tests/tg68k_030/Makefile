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
.PHONY: all clean test-pmmu test-cache test-cacr test-integration test-diagrom test-advanced test-fault test-stress test-regression test-cache-crash test-cache-crash-gui test-cache-focused test-caar test-caar-compliance test-caar-movec test-caar-permissions test-caar-reset test-caar-effects validate setup help

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
	@echo "  test-diagnostic  - Run PMMU diagnostic tests (RECOMMENDED FIRST)"
	@echo "  test-cache       - Test Cache component only"
	@echo "  test-cache-crash - Investigate cache enable crashes (DEBUGGING)"
	@echo "  test-cache-focused - Focused cache enable test (RECOMMENDED)"
	@echo "  test-cacr        - Test CACR register only"
	@echo "  test-caar        - Test CAAR register compliance (RECOMMENDED)"
	@echo "  test-caar-compliance - Comprehensive CAAR specification compliance"
	@echo "  test-caar-movec  - CAAR MOVEC instruction validation"
	@echo "  test-caar-permissions - CAAR access permissions (68020 vs 68030)"
	@echo "  test-caar-reset  - CAAR reset and cache effects"
	@echo "  test-caar-effects - CAAR side effects and special behaviors"
	@echo "  test-integration - Test full system integration"
	@echo "  test-diagrom     - Test DiagROM boot sequence"
	@echo "  test-advanced    - Run advanced PMMU functionality tests"
	@echo "  test-fault       - Run comprehensive fault handling tests"
	@echo "  test-stress      - Run page walker stress tests"
	@echo "  test-regression  - Run MC68030 regression test suite (RECOMMENDED)"
	@echo "  test-all         - Run original test suite"
	@echo "  test-comprehensive - Run ALL enhanced tests"
	@echo "  validate         - Validate complete MC68030 compliance"
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
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_pmmu_diagnostic.vhd || true
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

test-diagnostic: compile
	@echo "Running PMMU diagnostic tests..."
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 5us; quit" tb_pmmu_diagnostic

test-cache: compile
	@echo "Running Cache tests..."
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 30us; quit" tb_cache_030

test-cache-crash: setup
	@echo "Running Cache Enable Crash Investigation Test..."
	@echo "This test investigates why cache enable causes system crashes"
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Cache_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 tb_cache_enable_crash_test.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "do run_cache_enable_crash_test.tcl; exit" > cache_enable_crash_test.log 2>&1
	@echo ""
	@echo "=== CACHE CRASH INVESTIGATION RESULTS ==="
	@if grep -q "CACHE ENABLE CRASH DETECTED" cache_enable_crash_test.log; then \
		echo "🔴 CRASH CONFIRMED: Cache enable causes system hang"; \
		echo "📋 Check cache_enable_crash_test.log for details"; \
		echo "📋 Use 'make test-cache-crash-gui' for waveform analysis"; \
	elif grep -q "CACHE ENABLE SUCCESS" cache_enable_crash_test.log; then \
		echo "✅ SUCCESS: Cache enable works correctly"; \
		echo "📋 The issue may be environment-specific"; \
	else \
		echo "⚠️  INCONCLUSIVE: Check cache_enable_crash_test.log"; \
	fi
	@echo "=========================================="

test-cache-crash-gui: setup
	@echo "Starting Cache Enable Crash Investigation in GUI mode..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Cache_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 tb_cache_enable_crash_test.vhd
	@echo "Launching ModelSim GUI - use 'do run_cache_enable_crash_test.tcl' to run test"
	@cd $(TEST_DIR) && $(VSIM) -gui work.tb_cache_enable_crash_test &

test-cache-focused: setup
	@echo "Running Focused Cache Enable Test..."
	@echo "This test specifically targets cache enable/disable logic"
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Cache_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 tb_cache_enable_focused_test.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "do run_cache_focused_test.tcl; exit" > cache_focused_test.log 2>&1
	@echo ""
	@echo "=== FOCUSED CACHE TEST RESULTS ==="
	@if grep -q "CACHE ENABLE TEST FAILED" cache_focused_test.log; then \
		echo "🔴 FAILURE: Specific cache issues detected"; \
		echo "📋 Check cache_focused_test.log for details"; \
	elif grep -q "CACHE ENABLE TEST PASSED" cache_focused_test.log; then \
		echo "✅ SUCCESS: Cache enable/disable logic working"; \
		echo "📋 The system crash may be due to external factors"; \
	else \
		echo "⚠️  INCONCLUSIVE: Check cache_focused_test.log"; \
	fi
	@echo "========================================="

test-cacr: compile
	@echo "Running CACR tests..."
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 10us; quit" tb_cacr_test

# CAAR (Cache Address Access Register) Test Suite
test-caar: test-caar-compliance
	@echo "============================================"
	@echo "CAAR Register Test Suite Summary"
	@echo "============================================"
	@echo "All CAAR tests completed. Check individual logs for details."

test-caar-compliance: compile
	@echo "============================================"
	@echo "Running CAAR Specification Compliance Test"
	@echo "============================================"
	@cd $(TEST_DIR) && $(VSIM) -c -do "do run_caar_compliance_tests.tcl" 2>&1 | tee caar_compliance_test.log
	@if grep -q "ALL CAAR COMPLIANCE TESTS PASSED" caar_compliance_test.log; then \
		echo "✅ CAAR SPECIFICATION COMPLIANCE: PASSED"; \
	else \
		echo "❌ CAAR SPECIFICATION COMPLIANCE: ISSUES DETECTED"; \
		echo "Check caar_compliance_test.log for details"; \
	fi

test-caar-movec: compile
	@echo "Running CAAR MOVEC Instruction Validation..."
	@cd $(TEST_DIR) && $(VSIM) -c -do "vsim tb_caar_movec_validation; run 30us; quit -sim" 2>&1 | tee caar_movec_test.log
	@echo "CAAR MOVEC test completed. Check caar_movec_test.log for results."

test-caar-permissions: compile
	@echo "Running CAAR Access Permissions Test..."
	@cd $(TEST_DIR) && $(VSIM) -c -do "vsim tb_caar_permissions_test; run 25us; quit -sim" 2>&1 | tee caar_permissions_test.log
	@echo "CAAR permissions test completed. Check caar_permissions_test.log for results."

test-caar-reset: compile
	@echo "Running CAAR Reset and Cache Effects Test..."
	@cd $(TEST_DIR) && $(VSIM) -c -do "vsim tb_caar_reset_cache_effects; run 40us; quit -sim" 2>&1 | tee caar_reset_test.log
	@echo "CAAR reset test completed. Check caar_reset_test.log for results."

test-caar-effects: compile
	@echo "Running CAAR Side Effects Test..."
	@cd $(TEST_DIR) && $(VSIM) -c -do "vsim tb_caar_side_effects_test; run 35us; quit -sim" 2>&1 | tee caar_effects_test.log
	@echo "CAAR side effects test completed. Check caar_effects_test.log for results."

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

# MC68030 Regression Test Suite
test-regression: setup
	@echo "=========================================================="
	@echo "Running MC68030 PMMU Regression Test Suite"
	@echo "Validates all critical MC68030 compatibility fixes"
	@echo "=========================================================="
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 tb_mc68030_regression.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 50us; quit" work.tb_mc68030_regression > mc68030_regression_results.log 2>&1
	@echo "Regression test completed. Results in mc68030_regression_results.log"
	@echo ""
	@echo "=== REGRESSION TEST SUMMARY ==="
	@tail -10 mc68030_regression_results.log
	@echo ""

# MC68030 Compliance Validation  
validate: test-regression
	@echo "=========================================================="
	@echo "MC68030 COMPLIANCE VALIDATION"
	@echo "=========================================================="
	@if grep -q "ALL REGRESSION TESTS PASSED" mc68030_regression_results.log; then \
		echo "✅ MC68030 COMPLIANCE: FULLY VALIDATED"; \
		echo "✅ All critical MC68030 fixes are working correctly"; \
	elif grep -q "REGRESSION FAILURES DETECTED" mc68030_regression_results.log; then \
		echo "⚠️  MC68030 COMPLIANCE: SOME ISSUES DETECTED"; \
		echo "📋 Check mc68030_regression_results.log for details"; \
		echo "📋 Core functionality may still be working"; \
	else \
		echo "❌ MC68030 COMPLIANCE: VALIDATION INCOMPLETE"; \
		echo "📋 Check mc68030_regression_results.log for errors"; \
	fi
	@echo "=========================================================="
	@echo ""
	@echo "📁 Full results: mc68030_regression_results.log"
	@echo "📚 Documentation: README_MC68030_REGRESSION.md"

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
