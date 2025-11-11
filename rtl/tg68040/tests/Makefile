# TG68040 Test Makefile
#
# Targets:
#   make all        - Run all tests
#   make unit       - Run unit tests only
#   make integration - Run integration tests
#   make clean      - Clean build artifacts
#   make help       - Show this help

# VHDL compiler
GHDL := ghdl
GHDL_FLAGS := --std=08 --ieee=synopsys -frelaxed

# Directories
SRC_DIR := ../src
COMMON_DIR := common
UNIT_DIR := unit
INTEG_DIR := integration

# Source files
SRCS := $(SRC_DIR)/TG68040_Pack.vhd
COMMON_SRCS := $(COMMON_DIR)/test_pkg.vhd
UNIT_TESTS := $(wildcard $(UNIT_DIR)/test_*.vhd)
INTEG_TESTS := $(wildcard $(INTEG_DIR)/test_*.vhd)

# Build directory
WORK_DIR := work

.PHONY: all clean unit integration help

all: unit integration
	@echo "==================================="
	@echo "All tests completed successfully!"
	@echo "==================================="

unit: $(WORK_DIR)
	@echo "==================================="
	@echo "Running Unit Tests"
	@echo "==================================="
	@$(MAKE) -s compile-unit
	@$(MAKE) -s run-unit

integration: $(WORK_DIR)
	@echo "==================================="
	@echo "Running Integration Tests"
	@echo "==================================="
	@$(MAKE) -s compile-integration
	@$(MAKE) -s run-integration

# Create work directory
$(WORK_DIR):
	@mkdir -p $(WORK_DIR)

# Compile common files
compile-common: $(WORK_DIR)
	@echo "Compiling common source files..."
	@for src in $(SRCS); do \
		echo "  Analyzing $$src"; \
		$(GHDL) -a $(GHDL_FLAGS) --workdir=$(WORK_DIR) $$src || exit 1; \
	done
	@for src in $(COMMON_SRCS); do \
		echo "  Analyzing $$src"; \
		$(GHDL) -a $(GHDL_FLAGS) --workdir=$(WORK_DIR) $$src || exit 1; \
	done

# Compile unit tests
compile-unit: compile-common
	@echo "Compiling unit tests..."
	@for test in $(UNIT_TESTS); do \
		echo "  Analyzing $$test"; \
		$(GHDL) -a $(GHDL_FLAGS) --workdir=$(WORK_DIR) $$test || exit 1; \
	done

# Run unit tests
run-unit:
	@echo "Executing unit tests..."
	@for test in $(UNIT_TESTS); do \
		testname=$$(basename $$test .vhd); \
		echo ""; \
		echo "--- Running $$testname ---"; \
		$(GHDL) -e $(GHDL_FLAGS) --workdir=$(WORK_DIR) $$testname || exit 1; \
		$(GHDL) -r $(GHDL_FLAGS) --workdir=$(WORK_DIR) $$testname --stop-time=1us || exit 1; \
	done

# Compile integration tests
compile-integration: compile-common
	@echo "Compiling integration tests..."
	@if [ -n "$(INTEG_TESTS)" ]; then \
		for test in $(INTEG_TESTS); do \
			echo "  Analyzing $$test"; \
			$(GHDL) -a $(GHDL_FLAGS) --workdir=$(WORK_DIR) $$test || exit 1; \
		done; \
	else \
		echo "  No integration tests found yet."; \
	fi

# Run integration tests
run-integration:
	@if [ -n "$(INTEG_TESTS)" ]; then \
		echo "Executing integration tests..."; \
		for test in $(INTEG_TESTS); do \
			testname=$$(basename $$test .vhd); \
			echo ""; \
			echo "--- Running $$testname ---"; \
			$(GHDL) -e $(GHDL_FLAGS) --workdir=$(WORK_DIR) $$testname || exit 1; \
			$(GHDL) -r $(GHDL_FLAGS) --workdir=$(WORK_DIR) $$testname --stop-time=10us || exit 1; \
		done; \
	else \
		echo "No integration tests to run yet."; \
	fi

# Clean build artifacts
clean:
	@echo "Cleaning build artifacts..."
	@rm -rf $(WORK_DIR)
	@rm -f *.o *.cf
	@rm -f e~*.o
	@rm -f test_*
	@echo "Clean complete."

# Help
help:
	@echo "TG68040 Test Makefile"
	@echo ""
	@echo "Targets:"
	@echo "  make all         - Run all tests (unit + integration)"
	@echo "  make unit        - Run unit tests only"
	@echo "  make integration - Run integration tests only"
	@echo "  make clean       - Clean build artifacts"
	@echo "  make help        - Show this help"
	@echo ""
	@echo "Requirements:"
	@echo "  - GHDL (https://github.com/ghdl/ghdl)"
	@echo "  - GNU Make"
	@echo ""
	@echo "Example:"
	@echo "  $$ make unit"
	@echo "  $$ make clean"
