module eth_dma_addr_map
(
    input  wire [15:1] local_word_addr,
    output wire [28:1] ddr_word_addr
);

// Fixed DDR-backed 64KB Ethernet window at HPS physical 0x28EA0000-0x28EAFFFF.
localparam [28:1] ETH_SHMEM_BASE_WORD = 28'h1475000;

assign ddr_word_addr = ETH_SHMEM_BASE_WORD + local_word_addr;

endmodule
