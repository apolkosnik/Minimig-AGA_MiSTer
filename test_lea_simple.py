#!/usr/bin/env python3
"""
Simple LEA $2000,A7 instruction test simulation
Tests the Load Effective Address instruction behavior
"""

class M68KState:
    def __init__(self):
        self.pc = 0x100  # Program counter
        self.a7 = 0x400  # Stack pointer (A7)
        self.memory = {}
        
        # Set up test instruction: LEA $2000,A7
        # LEA.L $xxxx,A7 = 0x4FF9 followed by 32-bit address
        self.memory[0x100] = 0x4FF9  # LEA.L opcode
        self.memory[0x102] = 0x0000  # High word of $2000
        self.memory[0x104] = 0x2000  # Low word of $2000
    
    def read_word(self, addr):
        return self.memory.get(addr, 0)
    
    def execute_lea(self):
        """Execute LEA $2000,A7"""
        opcode = self.read_word(self.pc)
        print(f"PC: ${self.pc:04X}, Opcode: ${opcode:04X}")
        
        if opcode == 0x4FF9:  # LEA.L $xxxx,A7
            # Read 32-bit address
            addr_high = self.read_word(self.pc + 2)
            addr_low = self.read_word(self.pc + 4)
            effective_addr = (addr_high << 16) | addr_low
            
            print(f"LEA instruction: Load effective address ${effective_addr:08X} into A7")
            
            # Store effective address in A7
            old_a7 = self.a7
            self.a7 = effective_addr
            
            # Update PC
            self.pc += 6
            
            print(f"A7: ${old_a7:08X} -> ${self.a7:08X}")
            return True
        
        return False

def test_lea_instruction():
    print("Testing LEA $2000,A7 instruction")
    print("="*40)
    
    cpu = M68KState()
    print(f"Initial state:")
    print(f"  PC: ${cpu.pc:08X}")
    print(f"  A7: ${cpu.a7:08X}")
    print()
    
    success = cpu.execute_lea()
    
    print()
    print(f"Final state:")
    print(f"  PC: ${cpu.pc:08X}")
    print(f"  A7: ${cpu.a7:08X}")
    print()
    
    if success and cpu.a7 == 0x2000:
        print("✓ TEST PASSED: A7 correctly set to $00002000")
    else:
        print("✗ TEST FAILED: A7 not set correctly")
    
    print()
    print("Expected behavior:")
    print("- LEA loads the effective address (not the contents)")
    print("- The effective address $2000 should be loaded into A7")
    print("- PC should advance by 6 bytes (2 for opcode + 4 for address)")

if __name__ == "__main__":
    test_lea_instruction()