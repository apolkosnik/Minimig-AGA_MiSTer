# Makefile for TG68K 68030 Test Suite
# Provides easy commands to run comprehensive tests

# Paths
MODELSIM_PATH = /opt/intelFPGA_lite/17.0/modelsim_ase
VSIM = $(MODELSIM_PATH)/linuxaloem/vsim
VCOM = $(MODELSIM_PATH)/linuxaloem/vcom
VLIB = $(MODELSIM_PATH)/linuxaloem/vlib

TEST_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
PROJECT_ROOT := $(abspath $(TEST_DIR)/../..)
RTL_DIR := $(PROJECT_ROOT)/rtl/tg68k

# Test targets
.PHONY: all clean test-pmmu test-pmmu-reg test-pmmu-all-modes test-pmmu-walker test-pmmu-atc test-cache test-cacr test-movec-cacr test-movec-illegal test-movec-selector-latch test-cpsave-cprestore test-fpu-shell test-fpu-core-smoke test-mmu-library-detect test-mmu-library-failure-path test-mmu-library-root-probe test-mmu-library-enable-probe test-pmove-tc test-pmove-tc-read test-pmove-tt0-read test-pmove-tt0-mem-read test-pmove-tt1-mem test-pmove-readback-guard test-pmove-crp-a7-postinc test-pmove-crp-mem-to-mmu-postinc test-pmove-comprehensive test-pmove-multiple-regs test-pmove-d16an-pc test-pmove-d8anxn-pc test-pmove-all-modes test-integration test-diagrom test-diagrom-detectcpu test-cpu-mmu-detection test-advanced test-fault test-fault-recovery test-mmu-fetch-fault-frame test-mmu-user-data-fault-recovery test-stress test-regression test-pmove-addressing test-pflush-ptest-pload test-ptest-history-bits test-ptest-all-modes test-pload-all-modes test-pflush-all-modes test-pflush-illegal-pc-relative test-indirect-descriptor test-mmu-instruction-suite test-amiga-sequence test-moves test-moves-validation test-moves-privilege test-moves-d16an-pc test-moves-all-modes test-rte-formats test-rte-mbit-abcd test-abcd-mbit test-rte-abcd-suite test-arch-suite test-mmu-translation test-lockup-walker-timeout test-lockup-bus-conflict test-lockup-cache-fill test-lockup-atc-handshake test-lockup-mem-ack-race test-branch-odd-addr test-chk-long-odd-addr test-movec-active-stack test-interrupt-mode-stack test-lockup-all test-chk-stacked-trace test-basic-chk-trace test-basic-div-jmp-trace test-divs-word-overflow test-basic-chk2-cputest-entry test-basic-chk2-cputest-highaddr test-basic-chk2-packed-state test-basic-chk2-packed-group2 test-basic-jmp-cputest-entry test-basic-jmp-sp-disp-entry test-basic-jmp-sp-disp-highaddr test-basic-cputest-entry test-basic-exception-flags test-basic-group2-user-trace test-trace-post-rte-user test-basic-cputest test-basic-cputest-exact test-basic-cputest-exact-chk2bl test-basic-cputest-exact-chk2w test-basic-cputest-exact-jmp test-basic-cputest-runtime020 test-odd-exc-flags test-odd-irq-regwrite test-trace-suite test-group2-t0-trace test-group2-t1-trace test-group2-stacked-trace test-jmp-65b2-trace test-jmp-65b2-index-target test-jmp-record37-ori-tail test-real validate setup help prepare-basic-cputest-data

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
	@echo "  test-pmmu-reg    - Test PMMU register access, masks, and PMOVEFD behavior"
	@echo "  test-pmmu-walker - Test PMMU page table walker (7 comprehensive tests)"
	@echo "  test-pmmu-atc    - Test PMMU Address Translation Cache (10 comprehensive tests)"
	@echo "  test-pmmu-fault-req-change - Test PMMU stale-fault clear on changed transfer"
	@echo "  test-diagnostic  - Run PMMU diagnostic tests (RECOMMENDED FIRST)"
	@echo "  test-cache       - Test Cache component only"
	@echo "  test-cacr        - Test CACR register only"
	@echo "  test-movec-cacr  - Test MOVEC CACR corner cases"
	@echo "  test-movec-illegal - Test MOVEC to invalid register triggers trap"
	@echo "  test-mmu-library-detect - Test mmu.library style PMMU detection"
	@echo "  test-mmu-library-failure-path - Reproduce the photographed mmu.library CMP/BNE/JSR failure block"
	@echo "  test-mmu-library-root-probe - Test mmu.library CRP/SRP save/restore roundtrip"
	@echo "  test-mmu-library-enable-probe - Test mmu.library TC enable/MOVES probe/restore"
	@echo "  test-pmove-tc    - Test PMOVE Dx,TC (write) corner cases"
	@echo "  test-pmove-tc-read - Test PMOVE TC,Dx (read) corner cases"
	@echo "  test-pmove-tt0-read - Test PMOVE TT0,Dx (read) corner cases"
	@echo "  test-pmove-tt0-mem-read - Test PMOVE.L (d16,An),TT0 memory read (NEW)"
	@echo "  test-pmove-tt1-mem - Test PMOVE.L TT1,(d16,An) memory write"
	@echo "  test-pmove-readback-guard - Verify MMU->mem PMOVE does not clobber An while Dn readback still works"
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
	@echo "  test-advanced    - Run walker + ATC + translation PMMU suite"
	@echo "  test-fault       - Run fault recovery + frame/address fault suite"
	@echo "  test-mmu-fetch-fault-frame - Verify PMMU instruction fetch faults use long Format $$B at vector 2"
	@echo "  test-mmu-user-data-fault-recovery - Verify user-mode MMU data faults recover via vector 2 long frame + RTE"
	@echo "  test-stress      - Run translation and lockup/race stress suite"
	@echo "  test-real        - Run maintained real software-sequence validation suite"
	@echo "  test-regression  - Run MC68030 regression test suite (RECOMMENDED)"
	@echo "  test-pmove-addressing - Test PMOVE with all legal addressing modes"
	@echo "  test-pflush-ptest-pload - Test PFLUSH/PTEST/PLOAD instructions"
	@echo "  test-ptest-history-bits - Check leveled PTEST status and no-history behavior"
	@echo "  test-ptest-all-modes - Test PTEST with all EA modes and page table walks"
	@echo "  test-pload-all-modes - Test PLOAD with all EA modes and page table walks"
	@echo "  test-pflush-all-modes - Test 68030 PFLUSH forms (PFLUSHA/FC-mask/EA)"
	@echo "  test-pflush-illegal-pc-relative - Verify PC-relative PFLUSH traps as illegal"
	@echo "  test-indirect-descriptor - Test indirect descriptors"
	@echo "  test-mmu-instruction-suite - Run complete MMU instruction test suite"
	@echo "  test-amiga-sequence - Test Amiga ROM MMU initialization sequence"
	@echo "  test-moves       - Run maintained MOVES regression coverage"
	@echo "  test-moves-validation - Run maintained MOVES FC/privilege regression coverage"
	@echo "  test-moves-privilege - Verify MOVES traps with vector 8 in user mode"
	@echo "  test-moves-d16an-pc - Verify MOVES (d16,An) retires to the next instruction"
	@echo "  test-cpsave-cprestore - Verify cpSAVE/cpRESTORE privilege and F-line behavior"
	@echo "  test-rte-formats - Test all RTE stack frame formats (0,1,2,9,A,B + invalid)"
	@echo "  test-rte-mbit-abcd - Test RTE M-bit/S-bit transitions + ABCD interaction"
	@echo "  test-abcd-mbit - Test ABCD behavior with M-bit stack mode switching"
	@echo "  test-rte-abcd-suite - Run all RTE/ABCD regression benches"
	@echo "  test-arch-suite - Run maintained architecture/edge-case regression coverage"
	@echo "  test-chk-stacked-trace - Verify CHK/CHK2 stacked trace frames"
	@echo "  test-basic-chk-trace - Verify BASIC-style CHK/CHK2 user trace cases"
	@echo "  test-basic-div-jmp-trace - Verify BASIC-style DIV/JMP user trace cases"
	@echo "  test-divs-word-overflow - Verify DIVS.W register-direct overflow CCR"
	@echo "  test-basic-chk2-cputest-entry - Verify BASIC CHK2 first-post-RTE trace behavior"
	@echo "  test-basic-chk2-cputest-highaddr - Verify BASIC CHK2 split-2 behavior with full 0x420xxxxx addresses"
	@echo "  test-basic-chk2-packed-state - Reproduce the exact packed BASIC CHK2.W standalone-trace subcase"
	@echo "  test-basic-chk2-packed-group2 - Reproduce the exact packed BASIC CHK2.B/L Group 2 subcases"
	@echo "  test-basic-jmp-cputest-entry - Verify BASIC JMP first-post-RTE trace behavior"
	@echo "  test-basic-jmp-sp-disp-entry - Reproduce the packaged BASIC JMP (d16,SP) split-2 form"
	@echo "  test-basic-jmp-sp-disp-highaddr - Reproduce the packaged BASIC JMP (d16,SP) split with full 0x420xxxxx addresses"
	@echo "  test-basic-cputest-entry - Run the exact-form BASIC first-post-RTE CHK2/JMP reproducers"
	@echo "  test-basic-cputest-exact-chk2bl - Run exact packed BASIC CHK2.B/L group sweeps"
	@echo "  test-basic-cputest-exact-chk2w - Run exact packed BASIC CHK2.W group sweep"
	@echo "  test-basic-cputest-exact-jmp - Run exact packed BASIC JMP reproducer"
	@echo "  test-basic-cputest-runtime020 - Run focused BASIC CHK2/JMP cases through a WinUAE-style 020/030 exception harness"
	@echo "  test-basic-exception-flags - Verify BASIC-style CHK/DIV exception flag images"
	@echo "  test-basic-group2-user-trace - Verify BASIC-style TRAP/TRAPcc user stacked trace cases"
	@echo "  test-basic-cputest - Run maintained packaged BASIC opcode coverage for CHK/DIV/JMP/TRAP/TRAPcc"
	@echo "  test-odd-exc-flags - Verify direct CHK/DIV exception flag images behind ODD_EXC"
	@echo "  test-chk-long-odd-addr - Verify CHK.L odd data-source addresses still raise vector 6"
	@echo "  test-trace-suite - Run maintained T0/T1/Group 2 trace regression coverage"
	@echo "  test-jmp-65b2-trace - Verify the first post-RTE JMP 4EFB/65B2 still traces"
	@echo "  test-jmp-65b2-index-target - Verify the packaged JMP 4EFB/65B2 target and trace-side-effect shape"
	@echo "  test-jmp-record37-ori-tail - Reproduce the remaining ORI immediate-to-memory corruption from BASIC JMP/0002 record 37"
	@echo "  test-group2-t0-trace - Verify settled T0 Group 2 stacked trace cases"
	@echo "  test-group2-t1-trace - Verify settled T1 Group 2 stacked trace cases"
	@echo "  test-group2-stacked-trace - Run maintained Group 2 stacked trace coverage"
	@echo "  test-odd-irq-regwrite - Reproduce ODD_IRQ EXT*/SWAP retire-before-IRQ behavior"
	@echo "  test-branch-odd-addr - Odd-address branches & ISP/MSP integrity during mode transitions"
	@echo "  test-movec-active-stack - Verify MOVEC ISP/MSP active A7 aliasing for RTE"
	@echo "  test-movec-selector-latch - Verify MOVEC keeps its latched selector across later immediates"
	@echo "  test-interrupt-mode-stack - Verify RTE to supervisor M=1 switches active stack back to MSP"
	@echo "  test-mmu-translation - Comprehensive MMU translation pipeline test (walker + ATC + TT)"
	@echo "  test-berr-frame  - Test Format $$A bus error frame: SSW, fault address (BUG #414/#415)"
	@echo ""
	@echo "Lockup/Deadlock Tests (CRITICAL ISSUES):"
	@echo "  test-lockup-walker-timeout - Test walker timeout recovery (ISSUE #2)"
	@echo "  test-lockup-bus-conflict   - Test graphical DMA vs walker bus conflict (ISSUE #3)"
	@echo "  test-lockup-cache-fill     - Test cache fill starving walker (ISSUE #5)"
	@echo "  test-lockup-atc-handshake  - Test ATC completion handshake deadlock (ISSUE #4)"
	@echo "  test-lockup-mem-ack-race   - Test memory request ack race conditions (ISSUE #6)"
	@echo "  test-ddram-write-gap       - Test continuous two-word DDR write acknowledgement"
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
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_ttr_tc_disabled.vhd || true
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
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_mmu_translation.vhd || true
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_mmu_fault_recovery.vhd || true
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_addr_error_pmmu.vhd || true
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_berr_frame.vhd || true
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

test-pmmu-reg: setup
	@echo "=========================================================="
	@echo "Running PMMU Register Comprehensive Tests"
	@echo "Tests: register masks, enable transitions, MMUSR semantics,"
	@echo "       PMOVEFD, and register write/read stability"
	@echo "=========================================================="
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_pmmu_reg_comprehensive.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 20us; quit" tb_pmmu_reg_comprehensive

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

test-ddram-write-gap: setup
	@echo "Running DDR write-buffer continuous write test..."
	@cd $(TEST_DIR) && $(MODELSIM_PATH)/linuxaloem/vlog -sv $(PROJECT_ROOT)/rtl/cpu_cache_new.v $(PROJECT_ROOT)/rtl/ddram_ctrl.v $(TEST_DIR)/tb_ddram_write_gap.v
	@cd $(TEST_DIR) && $(VSIM) -c -do "run -all; quit" tb_ddram_write_gap

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

test-pmove-readback-guard: compile
	@echo "Running PMOVE readback-guard regression..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_pmove_readback_guard.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run 2ms; quit -f" tb_pmove_readback_guard

test-pmove-d16an-pc: compile
	@echo "Running PMOVE (d16,An) PC increment + data value tests..."
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 50us; quit" tb_pmove_d16an_pc

test-pmove-d8anxn-pc: compile
	@echo "Running PMOVE (d8,An,Xn) PC increment + data value tests..."
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 50us; quit" tb_pmove_d8anxn_pc

test-pmove-pc-all-regs: compile
	@echo "Running PMOVE PC increment test for ALL registers and addressing modes..."
	@echo "Tests: TC, TT0, TT1, CRP, SRP, MMUSR"
	@echo "Modes: (An), (d16,An), (d8,An,Xn), (xxx).W, (xxx).L"
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

test-pmove-comprehensive: test-pmove-all-modes test-pmove-readback-guard
	@echo "Maintained WinUAE PMOVE comprehensive regression complete."

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
	@cd $(TEST_DIR) && $(VSIM) -c -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run 10us; quit -f" tb_diagrom_detectcpu

test-cpu-mmu-detection: compile
	@echo "Running CPU/MMU detection tests (DiagROM PMOVE sequence)..."
	@cd $(TEST_DIR) && $(VSIM) -c -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run 50us; quit -f" tb_mmu_detection_test

test-68030-library: compile
	@echo "Running 68030.library PMOVE initialization test..."
	@cd $(TEST_DIR) && $(VSIM) -c -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run 10us; quit -f" tb_68030_library_init

test-ttr-tc-disabled: setup
	@echo "Running TC=0 transparent translation regression..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_ttr_tc_disabled.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run 20us; quit -f" tb_ttr_tc_disabled

test-whichamiga: compile
	@echo "Running WhichAmiga MMU instruction test..."
	@cd $(TEST_DIR) && $(VSIM) -c -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run 20us; quit -f" tb_whichamiga_mmu

# Early-termination PFA reproducer — verifies PS-sized ATC entries and
# PFA = TA + unused_LPA_bits for non-identity remaps and TA != 0 cases.
test-pmmu-early-term-remap: compile
	@echo "Compiling and running PMMU early-termination remap reproducer..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_pmmu_early_term_remap.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run 50us; quit -f" tb_pmmu_early_term_remap

test-pmmu-fault-req-change: setup
	@echo "Running PMMU fault/request-change regression..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_pmmu_fault_req_change.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run 20us; quit -f" tb_pmmu_fault_req_change

# Early-termination PFA reproducer - confirms PFA = TA + unused_LPA_bits for
# identity ($A0), remap-to-zero ($D0 -> $00), TA!=0 remap ($E0 -> $50) super-pages,
# and documents the degenerate TIA=0 case (blocked by MC68030 field-sum rule).
test-early-term-remap: compile
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_pmmu_early_term_remap.vhd
	@echo "Running PMMU early-termination remap reproducer..."
	@cd $(TEST_DIR) && $(VSIM) -c -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run 20us; quit -f" tb_pmmu_early_term_remap

# Comprehensive PMMU end-to-end coverage: fault MMUSR encoding, long-format
# (DT=11) descriptors, limit checking boundaries, TTR matching nuances, and
# attribute accumulation (WP across levels).
test-pmmu-comprehensive: compile
	@echo "Compiling and running PMMU comprehensive coverage test..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_pmmu_comprehensive.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run 500us; quit -f" tb_pmmu_comprehensive

# Wrapper-level PMMU/walker bench — instantiates cpu_wrapper.v (Verilog) to
# exercise integration paths the kernel-only benches cannot reach:
# walker ownership, walker-vs-cache-fill, BUG #422 stale-ready, BUG #439 RAM gap,
# BUG #424 watchdog escape, BUG #417 physical-address routing.
test-cpu-wrapper-pmmu: compile
	@echo "Compiling cpu_wrapper.v and wrapper-level PMMU bench..."
	@cd $(TEST_DIR) && $(MODELSIM_PATH)/linuxaloem/vlog -sv $(TEST_DIR)/altsource_probe_stub.v
	@cd $(TEST_DIR) && $(MODELSIM_PATH)/linuxaloem/vlog -sv $(PROJECT_ROOT)/rtl/cpu_wrapper.v
	@cd $(TEST_DIR) && $(MODELSIM_PATH)/linuxaloem/vlog -sv $(TEST_DIR)/tb_cpu_wrapper_pmmu.v
	@echo "Running wrapper-level PMMU test..."
	@cd $(TEST_DIR) && $(VSIM) -c -L work -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run 5ms; quit -f" tb_cpu_wrapper_pmmu

# Enhanced comprehensive tests
test-advanced: test-pmmu-walker test-pmmu-atc test-mmu-translation
	@echo "Advanced PMMU functionality suite complete."

test-fault-recovery: setup
	@echo "Running PMMU fault recovery tests..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_mmu_fault_recovery.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 120us; quit -f" tb_mmu_fault_recovery

test-mmu-fetch-fault-frame: setup
	@echo "Running PMMU instruction-fetch fault frame regression..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_mmu_fetch_fault_frame.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 120us; quit -f" tb_mmu_fetch_fault_frame

test-mmu-user-data-fault-recovery: setup
	@echo "Running user-mode MMU data fault recovery regression..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_mmu_user_data_fault_recovery.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 600us; quit -f" tb_mmu_user_data_fault_recovery

test-fault: test-fault-recovery test-mmu-fetch-fault-frame test-berr-frame test-addr-error-pmmu
	@echo "Fault handling suite complete."

test-stress: test-mmu-translation test-lockup-all
	@echo "Stress/race suite complete."

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

test-ptest-history-bits: setup
	@echo "Running PTEST leveled status regression..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_ptest_history_bits.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 20us; quit -f" tb_ptest_history_bits

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

test-pflush-illegal-pc-relative: setup
	@echo "Running illegal PC-relative PFLUSH regression..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_pflush_illegal_pc_relative.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 10us; quit -f" tb_pflush_illegal_pc_relative

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
	@cd $(TEST_DIR) && $(VSIM) -c -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run 30us; quit -f" tb_amiga_mmu_sequence

test-moves: test-moves-validation
	@echo "Maintained MOVES regression wrapper complete."

test-moves-validation: test-moves-all-modes test-moves-privilege test-moves-d16an-pc
	@echo "Maintained MOVES validation suite complete."

test-moves-privilege: setup
	@echo "Running MOVES privilege trap regression..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_moves_privilege.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 20us; quit -f" tb_moves_privilege

test-moves-d16an-pc: setup
	@echo "Running MOVES (d16,An) PC retire regression..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_moves_d16an_pc.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 50us; quit -f" tb_moves_d16an_pc

test-cpsave-cprestore: setup
	@echo "Running cpSAVE/cpRESTORE privilege/F-line regression..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_cpsave_cprestore_exceptions.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 80us; quit -f" tb_cpsave_cprestore_exceptions

test-fpu-shell: setup
	@echo "Running FPU shell regression..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_FPU_PackedDecimal.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_FPU_Converter.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_FPU_Decoder.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_FPU_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_FPU_Transcendental.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_FPU_ConstantROM.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_FPU_MOVEM.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_FPU_Exception_Handler.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_FPU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_fpu_shell.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run -all; quit -f" tb_fpu_shell
	@cd $(TEST_DIR) && $(VSIM) -c -gFPU_ENABLE_G=1 -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run -all; quit -f" tb_fpu_shell

test-fpu-core-smoke: setup
	@echo "Running imported FPU core smoke regression..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_FPU_PackedDecimal.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_FPU_Converter.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_FPU_Decoder.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_FPU_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_FPU_Transcendental.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_FPU_ConstantROM.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_FPU_MOVEM.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_FPU_Exception_Handler.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_FPU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_fpu_core_smoke.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 20us; quit -f" tb_fpu_core_smoke

test-stack-frame-push: setup
	@echo "Running stack frame push validation tests..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_stack_frame_push.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run 500us; quit -f" tb_stack_frame_push

test-chk-stacked-trace: setup
	@echo "Running CHK + stacked trace frame tests (BUG #439)..."
	@echo "Verifies two Format 2 frames pushed when CHK fires with T1=1"
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_chk_stacked_trace.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 1ms; quit" tb_chk_stacked_trace

test-chk-long-odd-addr: setup
	@echo "Running CHK.L odd data-source address regression..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_chk_long_odd_addr.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 100us; quit -f" tb_chk_long_odd_addr

test-group2-stacked-trace: setup
	@echo "Running maintained Group 2 stacked trace coverage..."
	@echo "Using the in-tree CHK/CHK2 bench plus maintained T0/T1 Group 2 coverage."
	@echo "Recovered old WinUAE-shaped T0 no-trace assertions are replaced by maintained 68030 trace checks; see 030_MMU_PORT_AUDIT.md."
	@$(MAKE) --no-print-directory test-chk-stacked-trace
	@$(MAKE) --no-print-directory test-group2-t0-trace
	@$(MAKE) --no-print-directory test-group2-t1-trace

test-basic-chk-trace: setup
	@echo "Running BASIC-style CHK/CHK2 user trace tests..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_basic_chk_trace.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run 2ms; quit -f" tb_basic_chk_trace

test-basic-div-jmp-trace: setup
	@echo "Running BASIC-style DIV/JMP user trace tests..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_basic_div_jmp_trace.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run 2ms; quit -f" tb_basic_div_jmp_trace

test-divs-word-overflow: setup
	@echo "Running DIVS.W word-overflow flag regression..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_divs_word_overflow_flags.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run 2ms; quit -f" tb_divs_word_overflow_flags

test-basic-chk2-cputest-entry: setup
	@echo "Running BASIC CHK2 cputest-entry trace tests..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_basic_chk2_cputest_entry.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run 4ms; quit -f" tb_basic_chk2_cputest_entry

test-basic-jmp-cputest-entry: setup
	@echo "Running BASIC JMP cputest-entry trace tests..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_basic_jmp_cputest_entry.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run 4ms; quit -f" tb_basic_jmp_cputest_entry

test-basic-jmp-sp-disp-entry: setup
	@echo "Running BASIC JMP (d16,SP) cputest-entry reproducer..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_basic_jmp_sp_disp_entry.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run 4ms; quit -f" tb_basic_jmp_sp_disp_entry

test-basic-jmp-sp-disp-highaddr: setup
	@echo "Running BASIC JMP (d16,SP) full-address reproducer..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_basic_jmp_sp_disp_highaddr.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run 4ms; quit -f" tb_basic_jmp_sp_disp_highaddr

test-basic-chk2-cputest-highaddr: setup
	@echo "Running BASIC CHK2 split-2 full-address reproducer..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_basic_chk2_cputest_highaddr.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run 8ms; quit -f" tb_basic_chk2_cputest_highaddr

test-basic-chk2-packed-state: setup
	@echo "Running exact packed BASIC CHK2.W standalone-trace reproducer..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_basic_chk2_packed_state.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run 4ms; quit -f" tb_basic_chk2_packed_state

test-basic-chk2-packed-group2: setup
	@echo "Running exact packed BASIC CHK2.B/L Group 2 reproducers..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_basic_chk2_packed_group2.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run 4ms; quit -f" tb_basic_chk2_packed_group2

test-basic-cputest-entry: setup
	@echo "Running exact-form BASIC first-post-RTE reproducers..."
	@$(MAKE) --no-print-directory test-basic-chk2-cputest-entry
	@$(MAKE) --no-print-directory test-basic-chk2-cputest-highaddr
	@$(MAKE) --no-print-directory test-basic-chk2-packed-state
	@$(MAKE) --no-print-directory test-basic-chk2-packed-group2
	@$(MAKE) --no-print-directory test-basic-jmp-cputest-entry
	@$(MAKE) --no-print-directory test-basic-jmp-sp-disp-highaddr

prepare-basic-cputest-data:
	@echo "Preparing BASIC cputest low-memory image..."
	@python3 $(TEST_DIR)/build_cputest_mem.py --out $(TEST_DIR)/data/cputest_basic_lmem.mem

test-basic-cputest-exact: setup prepare-basic-cputest-data
	@echo "Running exact packed BASIC CHK2/JMP reproducer (expected to fail until fixed)..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -2008 $(TEST_DIR)/tb_basic_cputest_exact.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run 4ms; quit -f" tb_basic_cputest_exact

test-basic-cputest-exact-chk2bl: setup prepare-basic-cputest-data
	@echo "Running exact packed BASIC CHK2.B/L group sweep..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -2008 $(TEST_DIR)/tb_basic_cputest_exact.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -gsuite_select=1 -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run 2ms; quit -f" tb_basic_cputest_exact

test-basic-cputest-exact-chk2w: setup prepare-basic-cputest-data
	@echo "Running exact packed BASIC CHK2.W group sweep..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -2008 $(TEST_DIR)/tb_basic_cputest_exact.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -gsuite_select=2 -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run 2ms; quit -f" tb_basic_cputest_exact

test-basic-cputest-exact-jmp: setup prepare-basic-cputest-data
	@echo "Running exact packed BASIC JMP reproducer..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -2008 $(TEST_DIR)/tb_basic_cputest_exact.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -gsuite_select=3 -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run 4ms; quit -f" tb_basic_cputest_exact

test-basic-cputest-runtime020: setup prepare-basic-cputest-data
	@echo "Running focused BASIC CHK2/JMP runtime020 harness reproducer..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -2008 $(TEST_DIR)/tb_basic_cputest_exact.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -gsuite_select=7 -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run 8ms; quit -f" tb_basic_cputest_exact

test-basic-exception-flags: setup
	@echo "Running BASIC-style CHK/DIV exception flag tests..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_basic_exception_flags.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run 2ms; quit -f" tb_basic_exception_flags

test-basic-group2-user-trace: setup
	@echo "Running BASIC-style TRAP/TRAPcc user trace tests..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_basic_group2_user_trace.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run 2ms; quit -f" tb_basic_group2_user_trace

test-trace-post-rte-user: setup
	@echo "Running post-RTE user stack trace regression..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_trace_post_rte_user.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run 2ms; quit -f" tb_trace_post_rte_user

test-basic-cputest: setup
	@echo "Running maintained BASIC opcode coverage..."
	@$(MAKE) --no-print-directory test-basic-chk-trace
	@$(MAKE) --no-print-directory test-basic-div-jmp-trace
	@$(MAKE) --no-print-directory test-divs-word-overflow
	@$(MAKE) --no-print-directory test-basic-cputest-entry
	@$(MAKE) --no-print-directory test-basic-exception-flags
	@$(MAKE) --no-print-directory test-basic-group2-user-trace
	@$(MAKE) --no-print-directory test-trace-post-rte-user

test-odd-exc-flags: setup
	@echo "Running direct ODD_EXC CHK/DIV flag tests..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_odd_exc_flags.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run 2ms; quit -f" tb_odd_exc_flags

test-odd-irq-regwrite: setup
	@echo "Running ODD_IRQ EXT*/SWAP retire-before-IRQ reproducer..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_odd_irq_regwrite.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run 2ms; quit -f" tb_odd_irq_regwrite

test-trace-suite: setup
	@echo "Running maintained trace regression suite..."
	@$(MAKE) --no-print-directory test-t0-trace
	@$(MAKE) --no-print-directory test-t1-trace
	@$(MAKE) --no-print-directory test-jmp-65b2-trace
	@$(MAKE) --no-print-directory test-group2-stacked-trace

test-group2-t0-trace: setup
	@echo "Running maintained T0 Group 2 stacked trace tests..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_group2_t0_trace.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run 5ms; quit -f" tb_group2_t0_trace

test-group2-t1-trace: setup
	@echo "Running maintained T1 Group 2 stacked trace tests..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_group2_t1_trace.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run 5ms; quit -f" tb_group2_t1_trace

test-rte-formats: setup
	@echo "Running RTE stack frame format validation tests..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_rte_all_formats.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 500us; quit" tb_rte_all_formats

test-rte-format-a-replay: setup
	@echo "Running RTE Format A LASTWRITE replay regression..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_rte_format_a_replay.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run 80us; quit -f" tb_rte_format_a_replay

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

test-rte-abcd-suite: test-rte-formats test-rte-mbit-abcd test-abcd-mbit test-movec-active-stack test-interrupt-mode-stack
	@echo "RTE/ABCD regression suite complete."

test-arch-suite: test-rte-abcd-suite test-abcd test-stack-frame-push test-branch-odd-addr test-chk-long-odd-addr test-odd-irq-regwrite test-odd-exc-flags test-basic-cputest test-movec-illegal test-movec-selector-latch test-cpsave-cprestore test-moves-validation test-ptest-history-bits
	@echo "Maintained architecture/edge-case suite complete."

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

test-addr-error-mmu-badfeed: setup
	@echo "Running odd BADFEED-backed MMU address-error regression..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_addr_error_mmu_badfeed.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 500us; quit -f" tb_addr_error_mmu_badfeed

test-mmu-badfeed-fault-frame: setup
	@echo "Running aligned BADFEED MMU fault-frame regression..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_mmu_badfeed_fault_frame.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 500us; quit -f" tb_mmu_badfeed_fault_frame

test-mmu-badfeed-softfix: setup
	@echo "Running BADFEED MMU software-fix recovery regression..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_mmu_badfeed_softfix_recovery.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 500us; quit -f" tb_mmu_badfeed_softfix_recovery

test-movec-active-stack: setup
	@echo "Running MOVEC active ISP/MSP -> A7 aliasing regression..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_movec_active_stack.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 50us; quit" tb_movec_active_stack

test-movec-selector-latch: setup
	@echo "Running MOVEC selector latch regression..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_movec_selector_latch.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 80us; quit -f" tb_movec_selector_latch

test-interrupt-mode-stack: setup
	@echo "Running interrupt-mode stack-selection regression..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_interrupt_mode_stack.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "run 80us; quit -f" tb_interrupt_mode_stack

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
	@cd $(TEST_DIR) && $(VSIM) -c -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run 30us; quit -f" tb_mmu_library_detect
#2>&1 | grep -E "(Note:.*PASS|Note:.*FAIL|Note:.*Results|Note:.*true|Note:.*false|Note:.*PMMU)"

test-mmu-library-failure-path: setup
	@echo "Running focused mmu.library failure-path reproducer..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_mmu_library_failure_path.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run 30us; quit -f" tb_mmu_library_failure_path

test-mmu-library-root-probe: setup
	@echo "Running mmu.library root pointer probe regression..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_mmu_library_root_probe.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run 50us; quit -f" tb_mmu_library_root_probe

test-mmu-library-enable-probe: setup
	@echo "Running mmu.library TC enable/MOVES probe/restore test..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_mmu_library_enable_probe.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run 50us; quit -f" tb_mmu_library_enable_probe

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
validate:
	@echo "=========================================================="
	@echo "MC68030 COMPLIANCE VALIDATION"
	@echo "=========================================================="
	@echo "Running maintained regression suite..."
	@$(MAKE) --no-print-directory test-regression
	@echo ""
	@echo "Running maintained trace suite..."
	@$(MAKE) --no-print-directory test-trace-suite
	@echo ""
	@echo "Running maintained architecture suite..."
	@$(MAKE) --no-print-directory test-arch-suite
	@echo ""
	@echo "Running maintained real software suite..."
	@$(MAKE) --no-print-directory test-real
	@echo ""
	@echo "=========================================================="
	@echo "MC68030 COMPLIANCE VALIDATION COMPLETE"
	@echo "Maintained regression, trace, architecture, and software suites passed."
	@echo "Full regression log: mc68030_regression_results.log"
	@echo "=========================================================="

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
test-comprehensive:
	@echo "=========================================================="
	@echo "Running TG68K 68030 Enhanced Comprehensive Test Suite"
	@echo "=========================================================="
	@echo "Running maintained PMMU functional suite..."
	@$(MAKE) --no-print-directory test-advanced
	@echo ""
	@echo "Running maintained fault-handling suite..."
	@$(MAKE) --no-print-directory test-fault
	@echo ""
	@echo "Running maintained lockup/race suite..."
	@$(MAKE) --no-print-directory test-lockup-all
	@echo ""
	@echo "Running maintained trace suite..."
	@$(MAKE) --no-print-directory test-trace-suite
	@echo ""
	@echo "Running maintained architecture suite..."
	@$(MAKE) --no-print-directory test-arch-suite
	@echo ""
	@echo "Running maintained real software suite..."
	@$(MAKE) --no-print-directory test-real
	@echo ""
	@echo "Running basic test suite..."
	@$(MAKE) --no-print-directory test-all
	@echo ""
	@echo "=========================================================="
	@echo "ALL ENHANCED COMPREHENSIVE TESTS COMPLETED!"
	@echo "=========================================================="
	@echo "Check the following files for results:"
	@ls -la $(TEST_DIR)/*.wlf 2>/dev/null || echo "No waveform files generated"

# Real software-sequence validation suite
test-real:
	@echo "=========================================================="
	@echo "Running maintained real software-sequence validation suite"
	@echo "=========================================================="
	@echo "Running DiagROM DetectCPU sequence..."
	@$(MAKE) --no-print-directory test-diagrom-detectcpu
	@echo ""
	@echo "Running DiagROM MMU detection sequence..."
	@$(MAKE) --no-print-directory test-cpu-mmu-detection
	@echo ""
	@echo "Running mmu.library detection sequence..."
	@$(MAKE) --no-print-directory test-mmu-library-detect
	@echo ""
	@echo "Running mmu.library root pointer probe..."
	@$(MAKE) --no-print-directory test-mmu-library-root-probe
	@echo ""
	@echo "Running mmu.library enable/probe/restore..."
	@$(MAKE) --no-print-directory test-mmu-library-enable-probe
	@echo ""
	@echo "Running 68030.library initialization sequence..."
	@$(MAKE) --no-print-directory test-68030-library
	@echo ""
	@echo "Running TC=0 transparent translation sequence..."
	@$(MAKE) --no-print-directory test-ttr-tc-disabled
	@echo ""
	@echo "Running WhichAmiga MMU sequence..."
	@$(MAKE) --no-print-directory test-whichamiga
	@echo ""
	@echo "Running Amiga ROM MMU initialization sequence..."
	@$(MAKE) --no-print-directory test-amiga-sequence
	@echo ""
	@echo "=========================================================="
	@echo "Real software-sequence validation suite complete."
	@echo "=========================================================="

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

test-jmp-65b2-trace: setup
	@echo "Running JMP 4EFB/65B2 trace regression..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_jmp_65b2_trace_regression.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run 2ms; quit -f" tb_jmp_65b2_trace_regression

test-jmp-65b2-index-target: setup
	@echo "Running packaged JMP 4EFB/65B2 target + trace-side-effect regression..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_jmp_65b2_index_target.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run 3ms; quit -f" tb_jmp_65b2_index_target

test-jmp-record37-ori-tail: setup
	@echo "Running focused BASIC JMP/0002 record 37 ORI tail reproducer..."
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_Pack.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_ALU.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68K_PMMU_030.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(RTL_DIR)/TG68KdotC_Kernel.vhd
	@cd $(TEST_DIR) && $(VCOM) -93 $(TEST_DIR)/tb_jmp_record37_ori_tail.vhd
	@cd $(TEST_DIR) && $(VSIM) -c -do "set StdArithNoWarnings 1; set NumericStdNoWarnings 1; run 40us; quit -f" tb_jmp_record37_ori_tail

