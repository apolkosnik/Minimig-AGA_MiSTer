// Minimig 32-bit Configuration Options
// Use these defines to control compilation features and resource usage

// =============================================================================
// 32-BIT BUS CONFIGURATION
// =============================================================================

// Enable 32-bit bus support (comment out to revert to 16-bit)
`define MINIMIG_32BIT_BUSES

// Strategic 32-bit optimization - keep buses where they matter most
`define STRATEGIC_32BIT_OPTIMIZATION

// Smart bus controller options
`ifdef MINIMIG_32BIT_BUSES
    `define SMART_BUS_CONTROLLER     // Enable dynamic 32/16-bit switching
    `define SHARED_SDRAM_CONTROLLER  // Use shared SDRAM control logic  
    // `define SMART_BUS_DEBUG          // Enable debug counters (remove for release)
`endif

// =============================================================================
// RESOURCE OPTIMIZATION LEVELS
// =============================================================================

// Level 1: Basic optimization (recommended)
`define OPTIMIZE_CUSTOM_CHIPS          // Keep custom chips at 16-bit
`define CHIPRAM_32BIT                  // Make chip RAM bus 32-bit wide

// Level 2: Aggressive optimization (for smaller FPGAs)
// `define OPTIMIZE_GAYLE_16BIT         // Force Gayle to 16-bit
// `define OPTIMIZE_MEMORY_SHARING      // Share memory controller logic

// Level 3: Maximum optimization (may affect performance)  
// `define OPTIMIZE_CONDITIONAL_32BIT   // Only use 32-bit for specific operations

// =============================================================================
// MEMORY CONFIGURATION
// =============================================================================

`define MISTER_DUAL_SDRAM
// Dual SDRAM support (requires MISTER_DUAL_SDRAM=1 in QSF)
`ifdef MISTER_DUAL_SDRAM
    `define DUAL_SDRAM_SUPPORT
`endif

// Memory bandwidth optimization
`ifdef MINIMIG_32BIT_BUSES
    `define MEMORY_BANDWIDTH_DOUBLING   // Enable 560 MB/s memory bandwidth
`endif

// =============================================================================
// CPU SUPPORT CONFIGURATION  
// =============================================================================

// CPU types that benefit from 32-bit buses
`define CPU_68020_32BIT_SUPPORT
`define CPU_68030_32BIT_SUPPORT  
`define CPU_68040_32BIT_SUPPORT

// =============================================================================
// COMPATIBILITY CONFIGURATION
// =============================================================================

// Maintain backward compatibility
`define LEGACY_16BIT_COMPATIBILITY     // Ensure 68000 works properly
//`define CHIP_RAM_16BIT_COMPAT          // Keep chip RAM access 16-bit compatible

// =============================================================================
// PERFORMANCE TUNING
// =============================================================================

// Bus width detection
`ifdef SMART_BUS_CONTROLLER
    `define AUTO_BUS_WIDTH_DETECTION    // Automatically detect optimal bus width
    `define PERFORMANCE_PRIORITY        // Prioritize performance over resources
`endif

// =============================================================================
// BUILD VARIANTS
// =============================================================================

// Uncomment ONE of these for different build variants:

// Default: Balanced performance and resource usage
// `define BUILD_VARIANT_BALANCED

// High Performance: Maximum 32-bit utilization
// `define BUILD_VARIANT_PERFORMANCE

// Resource Constrained: Minimal FPGA usage
// `define BUILD_VARIANT_MINIMAL

// Legacy: 16-bit compatible with 32-bit preparation
// `define BUILD_VARIANT_LEGACY

// Additional aggressive optimizations for current device constraints
//`define ULTRA_MINIMAL_BUILD  // Maximum resource savings

`define DISABLE_TOCCATA_32BIT    // Toccata at 16-bit
//`define DISABLE_CART_32BIT       // Cart at 16-bit

// =============================================================================
// CONDITIONAL FEATURE ENABLEMENT
// =============================================================================



`ifdef BUILD_VARIANT_PERFORMANCE
    `define FULL_32BIT_CUSTOM_CHIPS
    `define AGGRESSIVE_32BIT_USAGE
`endif

`ifdef BUILD_VARIANT_MINIMAL  
    `define OPTIMIZE_CUSTOM_CHIPS
    //`define OPTIMIZE_GAYLE_16BIT
    `define OPTIMIZE_MEMORY_SHARING
`endif

`ifdef ULTRA_MINIMAL_BUILD
    // Disable all advanced 32-bit features for resource savings
    `undef SMART_BUS_CONTROLLER
    `undef SHARED_SDRAM_CONTROLLER
    `undef SMART_BUS_DEBUG
    `undef AUTO_BUS_WIDTH_DETECTION
    `undef PERFORMANCE_PRIORITY
    
    // Keep only essential 32-bit paths
    `define CORE_32BIT_ONLY          // Only CPU-memory path is 32-bit
    //`define DISABLE_TOCCATA_32BIT    // Toccata at 16-bit
    `define DISABLE_CART_32BIT       // Cart at 16-bit
`endif


`ifdef BUILD_VARIANT_LEGACY
    `undef MINIMIG_32BIT_BUSES
    `define LEGACY_BUILD_MODE
`endif