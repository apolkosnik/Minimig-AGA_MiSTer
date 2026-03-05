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
.PHONY: all clean test-pmmu test-pmmu-all-modes test-pmmu-walker test-pmmu-atc test-cache test-cacr test-movec-cacr test-movec-illegal test-mmu-library-detect test-pmove-tc test-pmove-tc-read test-pmove-tt0-read test-pmove-tt0-mem-read test-pmove-tt1-mem test-pmove-crp-a7-postinc test-pmove-crp-mem-to-mmu-postinc test-pmove-comprehensive test-pmove-multiple-regs test-pmove-d16an-pc test-pmove-d8anxn-pc test-pmove-all-modes test-integration test-diagrom test-diagrom-detectcpu test-cpu-mmu-detection test-advanced test-fault test-stress test-regression test-pmove-addressing test-pflush-ptest-pload test-ptest-all-modes test-pload-all-modes test-pflush-all-modes test-indirect-descriptor test-mmu-instruction-suite test-amiga-sequence test-moves test-moves-validation test-moves-all-modes test-rte-formats test-rte-mbit-abcd test-abcd-mbit test-rte-abcd-suite test-mmu-translation test-lockup-walker-timeout test-lockup-bus-conflict test-lockup-cache-fill test-lockup-atc-handshake test-lockup-mem-ack-race test-branch-odd-addr test-movec-active-stack test-lockup-all test-chk-stacked-trace test-group2-stacked-trace validate setup help

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
	@echo "  test-pmmu-walker - Test PMMU page table walker (7 comprehensive tests)"
	@echo "  test-pmmu-atc    - Test PMMU Address Translation Cache (10 comprehensive tests)"
	@echo "  test-diagnostic  - Run PMMU diagnostic tests (RECOMMENDED FIRST)"
	@echo "  test-cache       - Test Cache component only"
	@echo "  test-cacr        - Test CACR register only"
	@echo "  test-movec-cacr  - Test MOVEC CACR corner cases"
	@echo "  test-movec-illegal - Test MOVEC to invalid register triggers trap"
	@echo "  test-mmu-library-detect - Test mmu.library style PMMU detection"
	@echo "  test-pmove-tc    - Test PMOVE Dx,TC (write) corner cases"
	@echo "  test-pmove-tc-read - Test PMOVE TC,Dx (read) corner cases"
	@echo "  test-pmove-tt0-read - Test PMOVE TT0,Dx (read) corner cases"
	@echo "  test-pmove-tt0-mem-read - Test PMOVE.L (d16,An),TT0 memory read (NEW)"
	@echo "  test-pmove-tt1-mem - Test PMOVE.L TT1,(d16,An) memory write"
	@echo "  test-pmove-crp-a7-postinc - Test PMOVE.Q CRP,(A7)+ stack update"
	@echo "  test-pmove-crp-mem-to-mmu-postinc - Test PMOVE.Q (A7)+,CRP memory-to-MMU read"
	@echo "  test-pmove-comprehensive - PMOVE encoding + d16,An regression"
	@echo "  test-pmove-d16an-pc - Test PMOVE (d16,An) PC increment + data values"
	@echo "  test-pmove-d8anxn-pc - Test PMOVE (d8,An,Xn) PC increment + data values"
	@echo "  test-pmove-pc-all-regs - COMPREHENSIVE: All regs (TC,TT0,TT1,CRP,SRP,MMUSR) + all EA modes"
	@echo "  test-pmove-all-modes - PMOVE all regs + all legal EA modes (stdout detail)"
	@echo "  test-pmove-multiple-regs - Test PMOVE multiple regs from (A7) - OP1addr conflict validation"
	@echo "  test-integration - Test full system integration"
	@echo "  test-diagrom     - Test DiagROM boot sequence"
	@echo "  test-diagrom-detectcpu - Test DiagROM CPU detection (MOVEC ITT0 trap)"
	@echo "  test-cpu-mmu-detection - Test CPU/MMU detection (TypeOfCPU + GetMMUType)"
	@echo "  test-68030-library - Test 68030.library PMOVE initialization (An mode)"
	@echo "  test-whichamiga  - Test WhichAmiga PMOVE TC/CRP and PTEST instructions"
	@echo "  test-advanced    - Run advanced PMMU functionality tests"
	@echo "  test-fault       - Run comprehensive fault handling tests"
	@echo "  test-stress      - Run page walker stress tests"
	@echo "  test-regression  - Run MC68030 regression test suite (RECOMMENDED)"
	@echo "  test-pmove-addressing - Test PMOVE with all legal addressing modes"
	@echo "  test-pflush-ptest-pload - Test PFLUSH/PTEST/PLOAD instructions"
	@echo "  test-ptest-all-modes - Test PTEST with all EA modes and page table walks"
	@echo "  test-pload-all-modes - Test PLOAD with all EA modes and page table walks"
	@echo "  test-pflush-all-modes - Test PFLUSH with all EA modes and variants (PFLUSHA/PFLUSHAN)"
	@echo "  test-indirect-descriptor - Test indirect descriptors"
	@echo "  test-mmu-instruction-suite - Run complete MMU instruction test suite"
	@echo "  test-amiga-sequence - Test Amiga ROM MMU initialization sequence"
	@echo "  test-moves       - Test MOVES instruction FC handling"
	@echo "  test-moves-validation - Run MOVES validation testbench"
	@echo "  test-rte-formats - Test all RTE stack frame formats (0,1,2,9,A,B + invalid)"
	@echo "  test-rte-mbit-abcd - Test RTE M-bit/S-bit transitions + ABCD interaction"
	@echo "  test-abcd-mbit - Test ABCD behavior with M-bit stack mode switching"
	@echo "  test-rte-abcd-suite - Run all RTE/ABCD regression benches"
	@echo "  test-branch-odd-addr - Odd-address branches & ISP/MSP integrity during mode transitions"
	@echo "  test-movec-active-stack - Verify MOVEC ISP/MSP active A7 aliasing for RTE"
	@echo "  test-mmu-translation - Comprehensive MMU translation pipeline test (walker + ATC + TT)"
	@echo "  test-berr-frame  - Test Format $$A bus error frame: SSW, fault address (BUG #414/#415)"
	@echo ""
	@echo "Lockup/Deadlock Tests (CRITICAL ISSUES):"
	@echo "  test-lockup-walker-timeout - Test walker timeout recovery (ISSUE #2)"
	@echo "  test-lockup-bus-conflict   - Test graphical DMA vs walker bus conflict (ISSUE #3)"
	@echo "  test-lockup-cache-fill     - Test cache fill starving walker (ISSUE #5)"
	@echo "  test-lockup-atc-handshake  - Test ATC completion handshake deadlock (ISSUE #4)"
	@echo "  test-lockup-mem-ack-race   - Test memory request ack race conditions (ISSUE #6)"
	@echo "  test-lockup-all            - Run ALL lockup/deadlock tests"
	@echo ""
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
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd || true
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Cache_030.vhd || true
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd || true
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_pmmu_030.vhd || true
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_cache_030.vhd || true
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_cacr_test.vhd || true
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_movec_cacr_corner.vhd || true
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_pmove_tc_corner.vhd || true
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_pmove_tc_read.vhd || true
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_pmove_tt0_read.vhd || true
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_pmove_tt0_mem_read.vhd || true
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_pmove_tt1_mem.vhd || true
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_pmove_crp_a7_postinc.vhd || true
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_pmove_comprehensive.vhd || true
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_pmove_multiple_regs_from_a7.vhd || true
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_pmmu_diagnostic.vhd || true
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_pmmu_all_modes_test.vhd || true
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_mmu_detection_test.vhd || true
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_pmove_d16an_pc.vhd || true
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_pmove_d8anxn_pc.vhd || true
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_pmove_all_modes.vhd || true
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/mock/tb_moves_validation.vhd || true
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_moves_all_modes.vhd || true
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/mock/tb_diagrom_detectcpu.vhd || true
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_68030_library_init.vhd || true
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_whichamiga_mmu.vhd || true
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_movec_active_stack.vhd || true
	@echo "Basic compilation completed (errors ignored for initial testing)"

# Compile enhanced test sources
compile-advanced: setup
	@echo "Compiling enhanced comprehensive test sources..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd || true
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Cache_030.vhd || true
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd || true
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_pmmu_030.vhd || true
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_cache_030.vhd || true
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_cacr_test.vhd || true
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_pmmu_walker_comprehensive.vhd || true
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_pmmu_atc_comprehensive.vhd || true
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_pmmu_advanced.vhd || true
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_mmu_fault_comprehensive.vhd || true
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_page_walker_stress.vhd || true
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_mmu_translation.vhd || true
	@echo "Enhanced compilation completed (errors ignored for initial testing)"

# Individual tests
test-pmmu: compile
	@echo "Running basic PMMU tests..."
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 50us; quit" tb_pmmu_030

test-pmmu-walker: setup
	@echo "=========================================================="
	@echo "Running PMMU Page Table Walker Comprehensive Tests"
	@echo "Tests: Basic walk, invalid descriptors, early termination,"
	@echo "       write protection, long format, supervisor, FCL mode"
	@echo "=========================================================="
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_pmmu_walker_comprehensive.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 100us; quit" tb_pmmu_walker_comprehensive

test-pmmu-atc: setup
	@echo "=========================================================="
	@echo "Running PMMU ATC (Address Translation Cache) Comprehensive Tests"
	@echo "Tests: Hit/miss, FC matching, I/D separation, variable page"
	@echo "       sizes, PFLUSHA, cache replacement, rapid accesses"
	@echo "=========================================================="
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_pmmu_atc_comprehensive.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 150us; quit" tb_pmmu_atc_comprehensive

test-pmmu-all-modes: compile
	@echo "Running PMMU all modes test..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_pmmu_all_modes_test.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 50us; quit" tb_pmmu_all_modes_test
#2>&1 | grep -E "(Note:.*PASS|Note:.*FAIL|Note:.*Results|Note:.*TEST)"

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

test-pmove-d16an-pc: compile
	@echo "Running PMOVE (d16,An) PC increment + data value tests..."
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 50us; quit" tb_pmove_d16an_pc

test-pmove-d8anxn-pc: compile
	@echo "Running PMOVE (d8,An,Xn) PC increment + data value tests..."
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 50us; quit" tb_pmove_d8anxn_pc

test-pmove-pc-all-regs: compile
	@echo "Running PMOVE PC increment test for ALL registers and addressing modes..."
	@echo "Tests: TC, TT0, TT1, CRP, SRP, MMUSR"
	@echo "Modes: Dn, (An), (An)+, -(An), (d16,An), (d8,An,Xn), (xxx).W, (xxx).L"
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_pmove_pc_all_regs.vhd && $(VSIM) -c -do "run 500us; quit" tb_pmove_pc_all_regs

test-pmove-all-modes: compile
	@echo "Running PMOVE all regs + all legal EA modes test..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_pmove_all_modes.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 3000us; quit" tb_pmove_all_modes

test-pmove-crp-a7-postinc: compile
	@echo "Running PMOVE.Q CRP,(A7)+ stack postincrement regression..."
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 5us; quit" tb_pmove_crp_a7_postinc

test-pmove-crp-mem-to-mmu-postinc: compile
	@echo "Running PMOVE.Q (A7)+,CRP memory-to-MMU postincrement test..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_pmove_crp_mem_to_mmu_postinc.vhd && $(VSIM) -c -do "run 5us; quit" tb_pmove_crp_mem_to_mmu_postinc

test-pmove-comprehensive: compile
	@echo "Running PMOVE comprehensive regression..."
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 500us; quit" tb_pmove_comprehensive

test-pmove-multiple-regs: compile
	@echo "Running PMOVE multiple registers from (A7) test (OP1addr conflict validation)..."
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 10us; quit" tb_pmove_multiple_regs_from_a7

test-integration: compile
	@echo "Running Integration tests..."
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 100us; quit" tb_integration_test

test-diagrom: compile
	@echo "Running DiagROM boot simulation..."
	@cd $(TEST_DIR) && $(VSIM) -c -do "do run_diagrom_boot.tcl; run 50us; quit"

test-diagrom-detectcpu: compile
	@echo "Running DiagROM DetectCPU tests (MOVEC ITT0 should trap on 68030)..."
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 10us; quit" tb_diagrom_detectcpu

test-cpu-mmu-detection: compile
	@echo "Running CPU/MMU detection tests (DiagROM PMOVE sequence)..."
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 50us; quit" tb_mmu_detection_test

test-68030-library: compile
	@echo "Running 68030.library PMOVE initialization test..."
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 10us; quit" tb_68030_library_init

test-whichamiga: compile
	@echo "Running WhichAmiga MMU instruction test..."
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 20us; quit" tb_whichamiga_mmu

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

test-pflush-ptest-pload: setup
	@echo "Running PFLUSH/PTEST/PLOAD tests..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_pflush_ptest_pload.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 30us; quit" tb_pflush_ptest_pload

test-ptest-all-modes: setup
	@echo "Running PTEST all addressing modes tests..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_ptest_all_modes.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 500us; quit" tb_ptest_all_modes

test-pload-all-modes: setup
	@echo "Running PLOAD all addressing modes tests..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_pload_all_modes.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 800us; quit" tb_pload_all_modes

test-pflush-all-modes: setup
	@echo "Running PFLUSH all addressing modes tests..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_pflush_all_modes.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 500us; quit" tb_pflush_all_modes

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
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/mock/tb_moves_instruction.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 10us; quit" tb_moves_instruction

test-moves-validation: setup
	@echo "Running MOVES validation testbench..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/mock/tb_moves_validation.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 30us; quit" tb_moves_validation

test-stack-frame-push: setup
	@echo "Running stack frame push validation tests..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_stack_frame_push.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 500us; quit" tb_stack_frame_push

test-chk-stacked-trace: setup
	@echo "Running CHK + stacked trace frame tests (BUG #439)..."
	@echo "Verifies two Format 2 frames pushed when CHK fires with T1=1"
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_chk_stacked_trace.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 1ms; quit" tb_chk_stacked_trace

test-group2-stacked-trace: setup
	@echo "Running Group 2 stacked trace tests (BUG #441/#442/#443)..."
	@echo "Tests CHK/TRAP/TRAPV/DIV0 with T1 and T0 trace modes"
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_group2_stacked_trace.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 5ms; quit" tb_group2_stacked_trace

test-rte-formats: setup
	@echo "Running RTE stack frame format validation tests..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_rte_all_formats.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 500us; quit" tb_rte_all_formats

test-rte-mbit-abcd: setup
	@echo "Running RTE M-bit/ABCD regression tests..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_rte_mbit_abcd.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run 10us; quit -f" tb_rte_mbit_abcd

test-abcd-mbit: setup
	@echo "Running ABCD M-bit regression tests..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_abcd_mbit.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run 5us; quit -f" tb_abcd_mbit

test-rte-abcd-suite: test-rte-formats test-rte-mbit-abcd test-abcd-mbit test-movec-active-stack
	@echo "RTE/ABCD regression suite complete."

test-branch-odd-addr: setup
	@echo "Running odd-address branch & ISP/MSP integrity tests..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_branch_odd_addr.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 300us; quit" tb_branch_odd_addr

test-addr-error-pmmu: setup
	@echo "Running address error with PMMU enabled tests..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_addr_error_pmmu.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 500us; quit -f" tb_addr_error_pmmu
#2>&1 | grep -E "(PASS|FAIL|Format|Test|Error|=====)"

test-movec-active-stack: setup
	@echo "Running MOVEC active ISP/MSP -> A7 aliasing regression..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_movec_active_stack.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 50us; quit" tb_movec_active_stack

# MOVEC Illegal Register Trap Test
test-movec-illegal: setup
	@echo "Running MOVEC illegal register trap test..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_movec_illegal.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 20us; quit" tb_movec_illegal
#2>&1 | grep -E "(Note:.*PASS|Note:.*FAIL|Note:.*Results|Note:.*true|Note:.*false|Note:.*SUCCESS)"

# ABCD/SBCD BCD Arithmetic Test
test-abcd: setup
	@echo "Running ABCD/SBCD BCD arithmetic test..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_abcd.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 200us; quit" tb_abcd

# MMU.library Style PMMU Detection Test
test-mmu-library-detect: setup
	@echo "Running mmu.library style PMMU detection test..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_mmu_library_detect.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 30us; quit" tb_mmu_library_detect
#2>&1 | grep -E "(Note:.*PASS|Note:.*FAIL|Note:.*Results|Note:.*true|Note:.*false|Note:.*PMMU)"

# MOVES All Addressing Modes Test
test-moves-all-modes: setup
	@echo "Running MOVES all addressing modes test..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_moves_all_modes.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 150us; quit" tb_moves_all_modes
#2>&1 | grep -E "(Note:.*TEST|Note:.*PASS|Note:.*FAIL|Note:.*Results|Note:.*RAM)"

test-pmove:
	vlib work
	vcom -93 $(RTL_DIR)/TG68K_Pack.vhd
	vcom -93 $(RTL_DIR)/TG68K_ALU.vhd
	vcom -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	vcom -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	vcom -93 tb_pmove.vhd
	vsim -c -do "run -all" tb_pmove

# Comprehensive MMU Translation Pipeline Test
test-mmu-translation: setup
	@echo "=========================================================="
	@echo "Running Comprehensive MMU Translation Test Suite"
	@echo "Tests: Page walking, address translation, PTEST, PFLUSH,"
	@echo "       TT registers, cache inhibit, write protection"
	@echo "=========================================================="
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_mmu_translation.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 250us; quit -f" tb_mmu_translation

# Bus Error Frame Test (BUG #414/#415)
test-berr-frame: setup
	@echo "=========================================================="
	@echo "Running Bus Error Frame (Format $$A) Test Suite"
	@echo "Tests: SSW fields, fault address, format/vector (BUG #414/#415)"
	@echo "=========================================================="
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_berr_frame.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 100us; quit -f" tb_berr_frame

# Lockup/Deadlock Tests - CRITICAL ISSUES
test-lockup-walker-timeout: setup
	@echo "=========================================================="
	@echo "Testing Walker Timeout Recovery (CRITICAL ISSUE #2)"
	@echo "Tests for incomplete timeout recovery causing deadlock"
	@echo "=========================================================="
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_lockup_walker_timeout.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 100us; quit" tb_lockup_walker_timeout

test-lockup-bus-conflict: setup
	@echo "=========================================================="
	@echo "Testing Graphical DMA vs Walker Bus Conflict (CRITICAL ISSUE #3)"
	@echo "Tests for bus collision between DMA and page table walker"
	@echo "=========================================================="
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_lockup_bus_conflict.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 150us; quit" tb_lockup_bus_conflict

test-lockup-cache-fill: setup
	@echo "=========================================================="
	@echo "Testing Cache Fill Starving Walker (CRITICAL ISSUE #5)"
	@echo "Tests for cache fills blocking page table walker indefinitely"
	@echo "=========================================================="
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_lockup_cache_fill.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 200us; quit" tb_lockup_cache_fill

test-lockup-atc-handshake: setup
	@echo "=========================================================="
	@echo "Testing ATC Completion Handshake (CRITICAL ISSUE #4)"
	@echo "Tests for missed walker_completed pulses causing deadlock"
	@echo "=========================================================="
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_lockup_atc_handshake.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 150us; quit" tb_lockup_atc_handshake

test-lockup-mem-ack-race: setup
	@echo "=========================================================="
	@echo "Testing Memory Request Ack Race (CRITICAL ISSUE #6)"
	@echo "Tests for mem_req/mem_ack handshaking getting out of sync"
	@echo "=========================================================="
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_lockup_mem_ack_race.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 150us; quit" tb_lockup_mem_ack_race

# Run all lockup/deadlock tests
test-lockup-all: test-lockup-walker-timeout test-lockup-bus-conflict test-lockup-cache-fill test-lockup-atc-handshake test-lockup-mem-ack-race
	@echo ""
	@echo "=========================================================="
	@echo "ALL LOCKUP/DEADLOCK TESTS COMPLETED"
	@echo "=========================================================="
	@echo ""
	@echo "Review results above for:"
	@echo "  - Walker timeout recovery (ISSUE #2)"
	@echo "  - Bus conflict deadlocks (ISSUE #3)"
	@echo "  - Cache fill starvation (ISSUE #5)"
	@echo "  - ATC handshake races (ISSUE #4)"
	@echo "  - Memory ack races (ISSUE #6)"
	@echo ""

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
	@echo "--- PTEST All Addressing Modes ---"
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_ptest_all_modes.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 500us; quit" tb_ptest_all_modes
	@echo ""
	@echo "--- PLOAD All Addressing Modes ---"
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_pload_all_modes.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 800us; quit" tb_pload_all_modes
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
	@echo "Running PMMU page table walker tests..."
	@cd $(TEST_DIR) && $(VSIM) -batch -do "vsim tb_pmmu_walker_comprehensive; run 100us; quit -sim"
	@echo ""
	@echo "Running PMMU ATC (translation cache) tests..."
	@cd $(TEST_DIR) && $(VSIM) -batch -do "vsim tb_pmmu_atc_comprehensive; run 150us; quit -sim"
	@echo ""
	@echo "Running advanced PMMU functionality tests..."
	@cd $(TEST_DIR) && $(VSIM) -batch -do "vsim tb_pmmu_advanced; run 200us; quit -sim"
	@echo ""
	@echo "Running comprehensive fault handling tests..."
	@cd $(TEST_DIR) && $(VSIM) -batch -do "vsim tb_mmu_fault_comprehensive; run 150us; quit -sim"
	@echo ""
	@echo "Running page walker stress tests..."
	@cd $(TEST_DIR) && $(VSIM) -batch -do "vsim tb_page_walker_stress; run 300us; quit -sim"
	@echo ""
	@echo "Running MMU translation comprehensive tests..."
	@cd $(TEST_DIR) && $(VSIM) -batch -do "vsim tb_mmu_translation; run 250us; quit -sim"
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

# Exception Stack Frame Verification
test-exceptions: $(BUILD_DIR)/tg68k.o
	$(GHDL) -a $(GHDL_FLAGS) tb_exceptions.vhd
	$(GHDL) -e $(GHDL_FLAGS) tb_exceptions
	$(GHDL) -r $(GHDL_FLAGS) tb_exceptions --vcd=$(BUILD_DIR)/tb_exceptions.vcd --stop-time=10us

# T0 Change-of-Flow Trace Mode Test
test-t0-trace: setup
	@echo "Running T0 change-of-flow trace mode tests..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_t0_trace.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run 2ms; quit -f" tb_t0_trace

test-t1-trace: setup
	@echo "Running T1 single-step trace mode tests..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_t1_trace.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run 2ms; quit -f" tb_t1_trace

