//------------------------------------------------------------------------------
// MC68060 Instruction Cache
// 8KB, 4-way set associative, 16-byte line size
// 128 sets × 4 ways × 16 bytes = 8KB
//------------------------------------------------------------------------------

module MC68060_ICache
(
    input  wire        clk,
    input  wire        nreset,
    input  wire        enable,

    input  wire [31:0] addr,
    input  wire [15:0] data_in,
    output wire [15:0] data_out,

    output wire        hit,
    output wire        valid
);

// Cache parameters
localparam SETS = 128;           // Number of sets
localparam WAYS = 4;             // 4-way set associative
localparam LINE_SIZE = 16;       // 16 bytes per line
localparam TAG_WIDTH = 21;       // 32 - 7 (index) - 4 (offset) = 21

// Address breakdown
wire [3:0]  offset = addr[3:0];
wire [6:0]  index  = addr[10:4];
wire [20:0] tag    = addr[31:11];

// Cache storage
reg [TAG_WIDTH-1:0] cache_tags [0:SETS-1][0:WAYS-1];
reg                 cache_valid [0:SETS-1][0:WAYS-1];
reg [127:0]         cache_data [0:SETS-1][0:WAYS-1];  // 16 bytes = 128 bits
reg [1:0]           lru [0:SETS-1][0:WAYS-1];         // LRU counters

// Hit detection
reg [WAYS-1:0] way_hit;
reg cache_hit;
integer w;

always @(*) begin
    cache_hit = 1'b0;
    way_hit = 4'b0000;
    for (w = 0; w < WAYS; w = w + 1) begin
        if (cache_valid[index][w] && (cache_tags[index][w] == tag)) begin
            cache_hit = 1'b1;
            way_hit[w] = 1'b1;
        end
    end
end

assign hit = cache_hit && enable;
assign valid = cache_hit;

// Data output (select correct word from cache line based on offset)
wire [1:0] word_sel = offset[3:1];  // Which word in the 16-byte line
reg [15:0] cache_data_out;

always @(*) begin
    cache_data_out = 16'h0;
    for (w = 0; w < WAYS; w = w + 1) begin
        if (way_hit[w]) begin
            case (word_sel)
                2'b00: cache_data_out = cache_data[index][w][15:0];
                2'b01: cache_data_out = cache_data[index][w][31:16];
                2'b10: cache_data_out = cache_data[index][w][47:32];
                2'b11: cache_data_out = cache_data[index][w][63:48];
            endcase
        end
    end
end

assign data_out = cache_data_out;

// Cache fill and LRU update logic
integer i, j;
always @(posedge clk or negedge nreset) begin
    if (!nreset) begin
        // Initialize cache
        for (i = 0; i < SETS; i = i + 1) begin
            for (j = 0; j < WAYS; j = j + 1) begin
                cache_tags[i][j] <= {TAG_WIDTH{1'b0}};
                cache_valid[i][j] <= 1'b0;
                cache_data[i][j] <= 128'h0;
                lru[i][j] <= j;
            end
        end
    end else if (enable) begin
        if (cache_hit) begin
            // Update LRU on cache hit
            for (w = 0; w < WAYS; w = w + 1) begin
                if (way_hit[w]) begin
                    lru[index][w] <= 2'd0;  // Most recently used
                end else if (lru[index][w] < 2'd3) begin
                    lru[index][w] <= lru[index][w] + 1'd1;
                end
            end
        end else begin
            // Cache miss - fill from memory (simplified)
            // In a real implementation, this would trigger a burst read
            // For now, just mark as a miss
        end
    end
end

endmodule
