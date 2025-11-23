//------------------------------------------------------------------------------
// MC68060 Data Cache
// 8KB, 4-way set associative, 16-byte line size, write-through
// 128 sets × 4 ways × 16 bytes = 8KB
//------------------------------------------------------------------------------

module MC68060_DCache
(
    input  wire        clk,
    input  wire        nreset,
    input  wire        enable,

    input  wire [31:0] addr,
    input  wire [15:0] data_in,
    output wire [15:0] data_out,
    input  wire        write,

    output wire        hit,
    output wire        valid
);

// Cache parameters
localparam SETS = 128;
localparam WAYS = 4;
localparam LINE_SIZE = 16;
localparam TAG_WIDTH = 21;

// Address breakdown
wire [3:0]  offset = addr[3:0];
wire [6:0]  index  = addr[10:4];
wire [20:0] tag    = addr[31:11];

// Cache storage
reg [TAG_WIDTH-1:0] cache_tags [0:SETS-1][0:WAYS-1];
reg                 cache_valid [0:SETS-1][0:WAYS-1];
reg [127:0]         cache_data [0:SETS-1][0:WAYS-1];
reg [1:0]           lru [0:SETS-1][0:WAYS-1];

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

// Data output
wire [1:0] word_sel = offset[3:1];
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

// Cache write and LRU update
integer i, j;
always @(posedge clk or negedge nreset) begin
    if (!nreset) begin
        for (i = 0; i < SETS; i = i + 1) begin
            for (j = 0; j < WAYS; j = j + 1) begin
                cache_tags[i][j] <= {TAG_WIDTH{1'b0}};
                cache_valid[i][j] <= 1'b0;
                cache_data[i][j] <= 128'h0;
                lru[i][j] <= j;
            end
        end
    end else if (enable) begin
        if (write) begin
            // Write-through: update cache and memory
            if (cache_hit) begin
                for (w = 0; w < WAYS; w = w + 1) begin
                    if (way_hit[w]) begin
                        case (word_sel)
                            2'b00: cache_data[index][w][15:0]   <= data_in;
                            2'b01: cache_data[index][w][31:16]  <= data_in;
                            2'b10: cache_data[index][w][47:32]  <= data_in;
                            2'b11: cache_data[index][w][63:48]  <= data_in;
                        endcase
                        lru[index][w] <= 2'd0;
                    end else if (lru[index][w] < 2'd3) begin
                        lru[index][w] <= lru[index][w] + 1'd1;
                    end
                end
            end
        end else if (cache_hit) begin
            // Read hit - update LRU
            for (w = 0; w < WAYS; w = w + 1) begin
                if (way_hit[w]) begin
                    lru[index][w] <= 2'd0;
                end else if (lru[index][w] < 2'd3) begin
                    lru[index][w] <= lru[index][w] + 1'd1;
                end
            end
        end
    end
end

endmodule
