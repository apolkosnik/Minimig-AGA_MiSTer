//
// FX68K Configuration Header
//
// Defines configuration options for FX68K CPU core
//

`ifndef FX68K_CONFIG_SVH
`define FX68K_CONFIG_SVH

// ============================================================================
// CPU Core Selection
// ============================================================================

// Define FX68K_SUPERSCALAR to enable superscalar core
// Comment out for cycle-accurate original core
// `define FX68K_SUPERSCALAR

// ============================================================================
// Superscalar Configuration (only used if FX68K_SUPERSCALAR defined)
// ============================================================================

`ifdef FX68K_SUPERSCALAR
    // Reorder Buffer Size (4, 8, or 16)
    `define SS_ROB_SIZE 8

    // Instruction Queue Size (4, 8, or 16)
    `define SS_IQ_SIZE 8

    // Number of Execution Units (2, 3, or 4)
    // 2: ALU0, LSU
    // 3: ALU0, ALU1, LSU
    // 4: ALU0, ALU1, AGU, LSU
    `define SS_NUM_EU 4

    // Enable Branch Prediction
    `define SS_BRANCH_PREDICT

    // Branch Target Buffer Size (16, 32, 64)
    `define SS_BTB_SIZE 64

    // Enable Out-of-Order Execution
    `define SS_OUT_OF_ORDER

    // Enable Register Renaming
    // `define SS_REGISTER_RENAME

    // Cache Configuration
    `define SS_ICACHE_SIZE 4096  // 4KB I-cache
    `define SS_DCACHE_SIZE 4096  // 4KB D-cache
    `define SS_CACHE_LINE_SIZE 32  // 32 bytes per line

    // Performance Counters
    `define SS_PERF_COUNTERS
`endif

// ============================================================================
// Common Configuration
// ============================================================================

// Clock Configuration
`define FX68K_CLOCK_MHZ 40

// Memory Interface Width
`define FX68K_DATA_WIDTH 16
`define FX68K_ADDR_WIDTH 24

// Debug Features
// `define FX68K_DEBUG
// `define FX68K_TRACE

// Synthesis Options
`define FX68K_OPTIMIZE_AREA     // Comment out to optimize for speed

`endif // FX68K_CONFIG_SVH
