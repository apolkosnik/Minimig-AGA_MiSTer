// Minimig Configuration Header
// This file contains compile-time configuration options for the Minimig core

//=============================================================================
// 32-BIT WIDE BUS CONFIGURATION
//=============================================================================
// Enable 32-bit wide data buses for TG68K CPU
// This widens the data bus from 16-bit to 32-bit for improved performance
// with TG68K processor
`define MINIMIG_TG68K_32BIT

// When enabled, the following changes are made:
// - TG68K data_in/data_write ports: 16-bit → 32-bit
// - TG68K byte enables: 2 strobes (UDS/LDS) → 4 byte enables (BE3:0)
// - CPU-Memory data buses: 16-bit → 32-bit
// - Memory controller data width: 16-bit → 32-bit
// - Bridge interfaces widened to 32-bit

`ifdef MINIMIG_TG68K_32BIT
    `define TG68K_DATA_WIDTH 32
    `define TG68K_BYTE_ENABLES 4
`else
    `define TG68K_DATA_WIDTH 16
    `define TG68K_BYTE_ENABLES 2
`endif

