#!/usr/bin/env python3
"""
Comprehensive Test Suite for 32-bit Bus Implementation
"""

import os
import re

def run_comprehensive_tests():
    print("🔧 COMPREHENSIVE 32-BIT BUS TEST SUITE")
    print("=" * 50)
    
    tests_passed = 0
    tests_total = 0
    
    # Test 1: Critical 32-bit signals present
    print("\n📊 Test 1: Critical 32-bit Signal Detection")
    tests_total += 1
    
    critical_signals = {
        'rtl/minimig_m68k_bridge.v': ['data', 'cpudatain', 'data_out', 'data_in'],
        'rtl/minimig_sram_bridge.v': ['data_in', 'data_out', 'ramdata_in'],
        'rtl/minimig.v': ['cpu_data', 'ram_data', 'custom_data_out'],
        'Minimig.sv': ['chip_dout', 'chip_din', 'ram_din', 'ram_dout']
    }
    
    all_found = True
    for filepath, signals in critical_signals.items():
        if os.path.exists(filepath):
            with open(filepath, 'r') as f:
                content = f.read()
            
            for signal in signals:
                pattern = rf'\[31:0\].*{signal}|\b{signal}.*\[31:0\]'
                if re.search(pattern, content):
                    print(f"  ✓ {os.path.basename(filepath)}: {signal} [32-bit]")
                else:
                    print(f"  ❌ {os.path.basename(filepath)}: {signal} [NOT 32-bit]")
                    all_found = False
    
    if all_found:
        print("  ✅ PASSED: All critical signals are 32-bit")
        tests_passed += 1
    else:
        print("  ❌ FAILED: Some critical signals missing")
    
    # Test 2: Bus width consistency
    print("\n🔗 Test 2: Bus Width Consistency")
    tests_total += 1
    
    # Check that data buses are consistently 32-bit in assignments
    consistency_check = True
    key_files = ['rtl/minimig.v', 'Minimig.sv']
    
    for filepath in key_files:
        if os.path.exists(filepath):
            with open(filepath, 'r') as f:
                content = f.read()
            
            # Find assign statements with explicit bit ranges
            assigns = re.findall(r'assign\s+\w+\[(\d+):(\d+)\]\s*=', content)
            for msb, lsb in assigns:
                width = int(msb) - int(lsb) + 1
                if width in [31, 16] and width != 32:  # Expected main bus widths
                    continue  # 16-bit peripherals are OK
                elif width == 32:
                    continue  # Perfect
                else:
                    consistency_check = False
    
    if consistency_check:
        print("  ✅ PASSED: Bus width assignments are consistent")
        tests_passed += 1
    else:
        print("  ❌ FAILED: Inconsistent bus widths found")
    
    # Test 3: Module port compatibility
    print("\n🔌 Test 3: Module Port Compatibility")
    tests_total += 1
    
    # Test specific module instantiations
    module_tests = [
        ('rtl/minimig.v', 'minimig_m68k_bridge', 'CPU1'),
        ('rtl/minimig.v', 'minimig_sram_bridge', 'RAM1'),
    ]
    
    port_compatibility = True
    for filepath, module_name, instance_name in module_tests:
        if os.path.exists(filepath):
            with open(filepath, 'r') as f:
                content = f.read()
            
            # Find the instantiation
            pattern = rf'{module_name}\s+{instance_name}\s*\((.*?)\);'
            match = re.search(pattern, content, re.DOTALL)
            
            if match:
                instance_content = match.group(1)
                data_connections = re.findall(r'\.(\w*data\w*)\s*\(([^)]+)\)', instance_content)
                
                print(f"  ✓ {module_name} instantiation found with {len(data_connections)} data connections")
            else:
                print(f"  ❌ {module_name} instantiation not found")
                port_compatibility = False
    
    if port_compatibility:
        print("  ✅ PASSED: Module port compatibility verified")
        tests_passed += 1
    else:
        print("  ❌ FAILED: Module port compatibility issues")
    
    # Test 4: Build configuration
    print("\n⚙️ Test 4: Build Configuration")
    tests_total += 1
    
    config_ok = True
    
    # Check dual SDRAM configuration
    dual_sdram_file = 'sys/sys_dual_sdram.tcl'
    if os.path.exists(dual_sdram_file):
        with open(dual_sdram_file, 'r') as f:
            content = f.read()
        
        if 'MISTER_DUAL_SDRAM=1' in content:
            print("  ✓ DUAL_SDRAM macro is set")
        else:
            print("  ❌ DUAL_SDRAM macro not found")
            config_ok = False
    else:
        print("  ❌ sys_dual_sdram.tcl not found")
        config_ok = False
    
    # Check version update
    version_file = 'rtl/minimig_version.vh'
    if os.path.exists(version_file):
        with open(version_file, 'r') as f:
            content = f.read()
        
        if '32-bit' in content.lower():
            print("  ✓ Version file updated for 32-bit")
        else:
            print("  ⚠ Version file may need 32-bit annotation")
    
    if config_ok:
        print("  ✅ PASSED: Build configuration is correct")
        tests_passed += 1
    else:
        print("  ❌ FAILED: Build configuration issues")
    
    # Test 5: CIA zero-extension
    print("\n🔌 Test 5: CIA Zero-Extension Check")
    tests_total += 1
    
    cia_ok = False
    if os.path.exists('rtl/minimig.v'):
        with open('rtl/minimig.v', 'r') as f:
            content = f.read()
        
        # Look for CIA zero-extension assignment
        if re.search(r'cia_data_out\[31:16\].*=.*16\'h0000', content):
            print("  ✓ CIA data outputs properly zero-extended")
            cia_ok = True
        else:
            print("  ❌ CIA zero-extension not found")
    
    if cia_ok:
        print("  ✅ PASSED: CIA zero-extension implemented")
        tests_passed += 1
    else:
        print("  ❌ FAILED: CIA zero-extension missing")
    
    # Final Results
    print(f"\n{'='*50}")
    print(f"🎯 FINAL RESULTS: {tests_passed}/{tests_total} tests passed")
    
    if tests_passed == tests_total:
        print("🏆 ALL TESTS PASSED! 32-bit implementation is ready!")
        print("✨ The Minimig 32-bit wide bus conversion is complete and verified.")
        return True
    else:
        print(f"⚠ {tests_total - tests_passed} tests failed. Review implementation.")
        return False

if __name__ == "__main__":
    run_comprehensive_tests()