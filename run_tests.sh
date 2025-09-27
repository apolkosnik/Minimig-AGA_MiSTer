#!/bin/bash

# Minimig 32-bit Regression Test Suite
# Quick test runner for validating the implementation

echo "🔧 Minimig 32-bit Regression Tests"
echo "=================================="

# Run all available tests
tests_passed=0
tests_total=0

# Test 1: 32-bit compatibility
if [ -f "test_32bit_compatibility.py" ]; then
    echo -n "Running 32-bit compatibility test... "
    if python3 test_32bit_compatibility.py > /dev/null 2>&1; then
        echo "✅ PASSED"
        ((tests_passed++))
    else
        echo "❌ FAILED"
    fi
    ((tests_total++))
fi

# Test 2: Integration test
if [ -f "test_integration.py" ]; then
    echo -n "Running integration test... "
    if python3 test_integration.py > /dev/null 2>&1; then
        echo "✅ PASSED"
        ((tests_passed++))
    else
        echo "❌ FAILED"
    fi
    ((tests_total++))
fi

# Test 3: Comprehensive test
if [ -f "test_comprehensive.py" ]; then
    echo -n "Running comprehensive test... "
    if python3 test_comprehensive.py > /dev/null 2>&1; then
        echo "✅ PASSED"
        ((tests_passed++))
    else
        echo "❌ FAILED"
    fi
    ((tests_total++))
fi

echo ""
echo "Results: $tests_passed/$tests_total tests passed"

if [ $tests_passed -eq $tests_total ]; then
    echo "🏆 ALL TESTS PASSED!"
    exit 0
else
    echo "❌ Some tests failed"
    exit 1
fi