`timescale 1ns / 1ps

module eth_dma_addr_map_tb;

reg  [15:1] local_word_addr;
wire [28:1] ddr_word_addr;

eth_dma_addr_map dut (
    .local_word_addr(local_word_addr),
    .ddr_word_addr(ddr_word_addr)
);

localparam [28:1] ETH_SHMEM_BASE_WORD = 28'h1475000;

task check_map;
    input [15:1] local_addr;
    reg   [28:1] expected;
    begin
        local_word_addr = local_addr;
        #1;
        expected = ETH_SHMEM_BASE_WORD + local_addr;
        if (ddr_word_addr !== expected) begin
            $display("FAIL: local=%04x expected=%08x got=%08x",
                     {local_addr, 1'b0}, {expected, 1'b0}, {ddr_word_addr, 1'b0});
            $finish(1);
        end
    end
endtask

initial begin
    check_map(15'h0000);
    check_map(15'h0600);
    check_map(15'h0800);
    check_map(15'h1800);
    check_map(15'h1BFF);
    check_map(15'h7FFF);

    $display("PASS: eth_dma_addr_map_tb completed");
    $finish;
end

endmodule
