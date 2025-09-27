#!/usr/bin/env python3
"""
32-bit Bus Compatibility Test Script
Tests data width consistency across modified modules
"""

import re
import os

def check_file_data_widths(filepath):
    """Check data width declarations in a file"""
    results = []
    try:
        with open(filepath, 'r') as f:
            content = f.read()
            
        # Find all data width declarations
        data_patterns = [
            r'(input|output|wire|reg)\s+\[(\d+):(\d+)\]\s+(\w*data\w*)',
            r'(input|output|wire|reg)\s+\[(\d+):(\d+)\]\s+(\w*din\w*)',
            r'(input|output|wire|reg)\s+\[(\d+):(\d+)\]\s+(\w*dout\w*)'
        ]
        
        for pattern in data_patterns:
            matches = re.findall(pattern, content, re.IGNORECASE)
            for match in matches:
                signal_type, msb, lsb, signal_name = match
                width = int(msb) - int(lsb) + 1
                results.append({
                    'file': os.path.basename(filepath),
                    'type': signal_type,
                    'signal': signal_name,
                    'width': width,
                    'declaration': f'[{msb}:{lsb}]'
                })
    except Exception as e:
        results.append({'error': f"Could not process {filepath}: {e}"})
    
    return results

def main():
    # Files to test
    test_files = [
        'rtl/minimig_m68k_bridge.v',
        'rtl/minimig_sram_bridge.v', 
        'rtl/cpu_wrapper.v',
        'rtl/minimig.v',
        'Minimig.sv'
    ]
    
    print("=== 32-bit Bus Compatibility Test ===\n")
    
    all_results = []
    for filepath in test_files:
        if os.path.exists(filepath):
            results = check_file_data_widths(filepath)
            all_results.extend(results)
        else:
            print(f"Warning: {filepath} not found")
    
    # Categorize results
    data_32bit = []
    data_16bit = []
    data_other = []
    
    for result in all_results:
        if 'error' in result:
            print(result['error'])
            continue
            
        if 'data' in result['signal'].lower():
            if result['width'] == 32:
                data_32bit.append(result)
            elif result['width'] == 16:
                data_16bit.append(result)
            else:
                data_other.append(result)
    
    # Report results
    print("32-bit Data Signals (Expected for main data paths):")
    for item in data_32bit:
        print(f"  ✓ {item['file']}: {item['signal']} {item['declaration']}")
    
    print(f"\n16-bit Data Signals (Should be peripherals only):")
    for item in data_16bit:
        print(f"  • {item['file']}: {item['signal']} {item['declaration']}")
    
    if data_other:
        print(f"\nOther Width Data Signals:")
        for item in data_other:
            print(f"  ? {item['file']}: {item['signal']} {item['declaration']} ({item['width']}-bit)")
    
    print(f"\n=== Summary ===")
    print(f"32-bit data signals found: {len(data_32bit)}")
    print(f"16-bit data signals found: {len(data_16bit)}")
    print(f"Other width signals found: {len(data_other)}")
    
    # Check for critical 32-bit signals
    critical_signals = ['cpu_data', 'ram_data', 'data_in', 'data_out']
    found_critical = []
    
    for result in all_results:
        if 'error' in result:
            continue
        for critical in critical_signals:
            if critical in result['signal'] and result['width'] == 32:
                found_critical.append(result['signal'])
    
    print(f"\nCritical 32-bit signals found: {len(set(found_critical))}")
    
    if len(data_32bit) >= 8:  # Expect at least 8 32-bit data signals
        print("\n✅ Test PASSED: Found sufficient 32-bit data signals")
        return True
    else:
        print("\n❌ Test FAILED: Insufficient 32-bit data signals")
        return False

if __name__ == "__main__":
    main()