# Makefile for TG68K 68030 Test Suite
# Provides easy commands to run comprehensive tests

# Paths
MODELSIM_PATH = /opt/intelFPGA_lite/17.0/modelsim_ase
VSIM = $(MODELSIM_PATH)/linuxaloem/vsim
VCOM = $(MODELSIM_PATH)/linuxaloem/vcom
VLIB = $(MODELSIM_PATH)/linuxaloem/vlib

PROJECT_ROOT = /home/adam/030_mmu/Minimig-AGA_MiSTer
TEST_DIR = $(PROJECT_ROOT)/tests/tg68k_030
RTL_DIR = $(PROJECT_ROOT)/rtl/tg68k

# Test targets
.PHONY: all clean test-pmmu test-cache test-cacr test-movec-cacr test-pmove-tc test-pmove-tc-read test-pmove-tt0-read test-pmove-tt0-mem-read test-pmove-tt1-mem test-pmove-multiple-regs test-integration test-diagrom test-cpu-mmu-detection test-advanced test-fault test-stress test-regression test-pmove-addressing test-pmove-cpu-execution test-pflush-ptest-pload test-indirect-descriptor test-mmu-instruction-suite test-amiga-sequence test-moves validate setup help

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
	@echo "  test-cacr        - Test CACR register only"
	@echo "  test-movec-cacr  - Test MOVEC CACR corner cases"
	@echo "  test-pmove-tc    - Test PMOVE Dx,TC (write) corner cases"
	@echo "  test-pmove-tc-read - Test PMOVE TC,Dx (read) corner cases"
	@echo "  test-pmove-tt0-read - Test PMOVE TT0,Dx (read) corner cases"
	@echo "  test-pmove-tt0-mem-read - Test PMOVE.L (d16,An),TT0 memory read (NEW)"
	@echo "  test-pmove-tt1-mem - Test PMOVE.L TT1,(d16,An) memory write"
	@echo "  test-pmove-multiple-regs - Test PMOVE multiple regs from (A7) - OP1addr conflict validation"
	@echo "  test-integration - Test full system integration"
	@echo "  test-diagrom     - Test DiagROM boot sequence"
	@echo "  test-cpu-mmu-detection - Test CPU/MMU detection (TypeOfCPU + GetMMUType)"
	@echo "  test-advanced    - Run advanced PMMU functionality tests"
	@echo "  test-fault       - Run comprehensive fault handling tests"
	@echo "  test-stress      - Run page walker stress tests"
	@echo "  test-regression  - Run MC68030 regression test suite (RECOMMENDED)"
	@echo "  test-pmove-addressing - Test PMOVE with all legal addressing modes"
	@echo "  test-pmove-cpu-execution - Test PMOVE via CPU execution (PC tracking)"
	@echo "  test-pflush-ptest-pload - Test PFLUSH/PTEST/PLOAD instructions"
	@echo "  test-indirect-descriptor - Test indirect descriptors"
	@echo "  test-mmu-instruction-suite - Run complete MMU instruction test suite"
	@echo "  test-amiga-sequence - Test Amiga ROM MMU initialization sequence"
	@echo "  test-moves       - Test MOVES instruction FC handling"
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
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_movec_cacr_corner.vhd || true
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_pmove_tc_corner.vhd || true
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_pmove_tc_read.vhd || true
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_pmove_tt0_read.vhd || true
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_pmove_tt0_mem_read.vhd || true
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_pmove_tt1_mem.vhd || true
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_pmove_multiple_regs_from_a7.vhd || true
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

test-cacr: compile
	@echo "Running CACR tests..."
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 10us; quit" tb_cacr_test

test-movec-cacr: compile
	@echo "Running MOVEC CACR corner case tests..."
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 10us; quit" tb_movec_cacr_corner

test-pmove-tc: compile
	@echo "Running PMOVE Dx,TC (write) corner case tests..."
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 10us; quit" tb_pmove_tc_corner

test-pmove-tc-read: compile
	@echo "Running PMOVE TC,Dx (read) corner case tests..."
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 10us; quit" tb_pmove_tc_read

test-pmove-tt0-read: compile
	@echo "Running PMOVE TT0,Dx (read) corner case tests..."
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 10us; quit" tb_pmove_tt0_read

test-pmove-tt0-mem-read: compile
	@echo "Running PMOVE.L (d16,An),TT0 (memory read) tests..."
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 10us; quit" tb_pmove_tt0_mem_read

test-pmove-tt1-mem: compile
	@echo "Running PMOVE.L TT1,(d16,An) memory write tests..."
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 10us; quit" tb_pmove_tt1_mem

test-pmove-multiple-regs: compile
	@echo "Running PMOVE multiple registers from (A7) test (OP1addr conflict validation)..."
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 10us; quit" tb_pmove_multiple_regs_from_a7

test-integration: compile
	@echo "Running Integration tests..."
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 100us; quit" tb_integration_test

test-diagrom: compile
	@echo "Running DiagROM boot simulation..."
	@cd $(TEST_DIR) && $(VSIM) -c -do "do run_diagrom_boot.tcl; run 50us; quit"

test-cpu-mmu-detection: compile
	@echo "Running CPU/MMU detection tests (TypeOfCPU + GetMMUType)..."
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 50us; quit" tb_cpu_mmu_detection

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

# New MMU instruction tests
test-pmove-addressing: setup
	@echo "Running PMOVE addressing modes tests..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_pmove_addressing_modes.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 20us; quit" tb_pmove_addressing_modes

test-pmove-cpu-execution: setup
	@echo "Running PMOVE CPU execution tests (PC tracking)..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_pmove_cpu_execution.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 50us; quit" tb_pmove_cpu_execution

test-pflush-ptest-pload: setup
	@echo "Running PFLUSH/PTEST/PLOAD tests..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_pflush_ptest_pload.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 30us; quit" tb_pflush_ptest_pload

test-indirect-descriptor: setup
	@echo "Running indirect descriptor tests..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_indirect_descriptor.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 30us; quit" tb_indirect_descriptor

test-amiga-sequence: setup
	@echo "Running Amiga ROM MMU initialization sequence test..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_amiga_mmu_sequence.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 30us; quit" tb_amiga_mmu_sequence

test-moves: setup
	@echo "Running MOVES instruction FC handling test..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_moves_instruction.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 10us; quit" tb_moves_instruction

# Complete MMU Instruction Test Suite
test-mmu-instruction-suite: setup
	@echo "=========================================================="
	@echo "Running Complete MMU Instruction Test Suite"
	@echo "=========================================================="
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd || true
	@echo ""
	@echo "--- PMOVE Addressing Modes ---"
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_pmove_addressing_modes.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 20us; quit" tb_pmove_addressing_modes
	@echo ""
	@echo "--- PFLUSH/PTEST/PLOAD ---"
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_pflush_ptest_pload.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 30us; quit" tb_pflush_ptest_pload
	@echo ""
	@echo "--- Indirect Descriptors ---"
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_indirect_descriptor.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 30us; quit" tb_indirect_descriptor
	@echo ""
	@echo "--- Amiga MMU Sequence ---"
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_amiga_mmu_sequence.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 30us; quit" tb_amiga_mmu_sequence
	@echo ""
	@echo "=========================================================="
	@echo "MMU Instruction Test Suite Complete"
	@echo "=========================================================="

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
