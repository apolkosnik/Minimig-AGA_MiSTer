/*
 * Simple Ethernet Register Test
 * Tests the local NE2000 register window plus the synthetic transmit-complete
 * behavior implemented in rtl/ethernet.v.
 * Compile with: gcc -m68000 -o ethernet_test ethernet_register_test.c
 */

#include <stdio.h>
#include <stdint.h>

// Ethernet register base address (configured via autoconfig)
#define ETH_BASE 0xEA0000

// NE2000 register offsets 
#define CR_REG    0x0C00   // Command Register
#define TPSR_REG  0x0C10   // Transmit Page Start Register
#define TBCR0_REG 0x0C14   // Transmit Byte Count low
#define TBCR1_REG 0x0C18   // Transmit Byte Count high
#define ISR_REG   0x0C1C   // Interrupt Status Register
#define IMR_REG   0x0C3C   // Interrupt Mask Register
#define DATA_PORT 0x0C40   // Data Port

// Register access macros
#define ETH_READ_REG(reg)     (*(volatile uint8_t*)(ETH_BASE + (reg)))
#define ETH_WRITE_REG(reg, val) (*(volatile uint8_t*)(ETH_BASE + (reg)) = (val))

// Test result structure
typedef struct {
    int test_passed;
    int read_test_passed;
    int write_test_passed;
    int tx_test_passed;
    int no_lockup;
    uint8_t cr_value;
    uint8_t isr_value;
} test_results_t;

test_results_t test_ethernet_registers(void) {
    test_results_t results = {0};
    uint8_t original_cr, test_value, read_back;
    
    printf("Starting Ethernet Register Test...\n");
    
    // Test 1: Basic register read (should not cause lockup)
    printf("Test 1: Reading CR register...\n");
    original_cr = ETH_READ_REG(CR_REG);
    printf("  CR = 0x%02X\n", original_cr);
    results.cr_value = original_cr;
    results.read_test_passed = 1; // If we get here, read didn't lock up
    
    // Test 2: Basic register write (should not cause lockup)
    printf("Test 2: Writing to CR register...\n");
    test_value = 0x21; // Stop command
    ETH_WRITE_REG(CR_REG, test_value);
    printf("  Wrote 0x%02X to CR\n", test_value);
    
    // Test 3: Read back to verify write
    printf("Test 3: Reading back CR register...\n");
    read_back = ETH_READ_REG(CR_REG);
    printf("  CR read back = 0x%02X\n", read_back);
    
    if (read_back == test_value) {
        printf("  ✓ Write/read test PASSED\n");
        results.write_test_passed = 1;
    } else {
        printf("  ✗ Write/read test FAILED (expected 0x%02X, got 0x%02X)\n", 
               test_value, read_back);
    }
    
    // Test 4: Test ISR register
    printf("Test 4: Reading ISR register...\n");
    results.isr_value = ETH_READ_REG(ISR_REG);
    printf("  ISR = 0x%02X\n", results.isr_value);
    
    // Test 5: Multiple register access
    printf("Test 5: Multiple register access...\n");
    for (int i = 0; i < 10; i++) {
        ETH_WRITE_REG(CR_REG, 0x21);
        uint8_t val = ETH_READ_REG(CR_REG);
        if (val != 0x21) {
            printf("  ✗ Multiple access test failed at iteration %d\n", i);
            goto test_complete;
        }
    }
    printf("  ✓ Multiple access test PASSED\n");

    // Test 6: Synthetic transmit completion
    printf("Test 6: Synthetic transmit completion...\n");
    ETH_WRITE_REG(ISR_REG, 0xFF);   // Clear any pending status bits
    ETH_WRITE_REG(IMR_REG, 0x02);   // Enable PTX interrupt
    ETH_WRITE_REG(TPSR_REG, 0x40);  // Valid default transmit page
    ETH_WRITE_REG(TBCR0_REG, 0x20); // Non-zero length required by the RTL model
    ETH_WRITE_REG(TBCR1_REG, 0x00);
    ETH_WRITE_REG(CR_REG, 0x06);    // STA + TXP

    for (int i = 0; i < 32; i++) {
        results.isr_value = ETH_READ_REG(ISR_REG);
        if (results.isr_value & 0x02) {
            results.tx_test_passed = 1;
            break;
        }
    }

    if (results.tx_test_passed) {
        printf("  PTX observed in ISR (0x%02X)\n", results.isr_value);
    } else {
        printf("  PTX not observed, ISR = 0x%02X\n", results.isr_value);
    }
    
    // Restore original value
    ETH_WRITE_REG(CR_REG, original_cr);
    
    results.no_lockup = 1;
    results.test_passed = results.read_test_passed &&
                          results.write_test_passed &&
                          results.tx_test_passed;
    
test_complete:
    printf("Ethernet Register Test Complete\n");
    return results;
}

void print_memory_mapping_info(void) {
    printf("\n=== Memory Mapping Information ===\n");
    printf("Ethernet Base:     0x%06X\n", ETH_BASE);
    printf("CR Register:       0x%06X -> Local NE2000 register window\n", ETH_BASE + CR_REG);
    printf("ISR Register:      0x%06X -> Local interrupt/status register\n", ETH_BASE + ISR_REG);
    printf("IMR Register:      0x%06X -> Local interrupt mask register\n", ETH_BASE + IMR_REG);
    printf("Data Port:         0x%06X -> Shared-memory DMA path into NE2000 RAM\n", ETH_BASE + DATA_PORT);
    printf("\nCurrent RTL model:\n");
    printf("  0xEA0C00-0xEA0C3F are handled locally by rtl/ethernet.v\n");
    printf("  0xEA0C40 uses the external DMA path into the DDR-backed NE2000 window\n");
}

int main(void) {
    printf("=== Ethernet Register Smoke Test ===\n");
    
    print_memory_mapping_info();
    
    printf("\n");
    test_results_t results = test_ethernet_registers();
    
    printf("\n=== Test Summary ===\n");
    printf("Overall Result:    %s\n", results.test_passed ? "PASS" : "FAIL");
    printf("No Lockups:        %s\n", results.no_lockup ? "✓" : "✗");
    printf("Read Test:         %s\n", results.read_test_passed ? "✓" : "✗");
    printf("Write Test:        %s\n", results.write_test_passed ? "✓" : "✗");
    printf("TX Test:           %s\n", results.tx_test_passed ? "✓" : "✗");
    printf("CR Value:          0x%02X\n", results.cr_value);
    printf("ISR Value:         0x%02X\n", results.isr_value);
    
    if (results.test_passed) {
        printf("\n✓ Local register access and TX completion appear to be working.\n");
        printf("Next step: exercise packet DMA and loopback/receive behavior on target.\n");
    } else {
        printf("\n✗ The local register/TX path still has issues.\n");
        printf("Check the Ethernet register window and ISR/PTX behavior.\n");
    }
    
    return results.test_passed ? 0 : 1;
}
