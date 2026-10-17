//--------------------------------------------------------------------------//
// AP020 - MC68020 compatible CPU                                           //
//                                                                          //
// ap020_fastram_be.v - DDR3 side of the AP020 Fast RAM port: executes the  //
// commands of ap020_fastram_fe (via the command FIFO) as Avalon-MM         //
// transfers on the 64-bit DDRAM interface.                                 //
//   write: one beat with byte enables                                      //
//   read:  a two-beat burst for a 16-byte line; both beats go to the       //
//          response FIFO in order                                          //
// Commands execute strictly in order, so a read never passes a write.     //
// A read is issued only when the response FIFO has room for its beats.    //
//--------------------------------------------------------------------------//

module ap020_fastram_be
(
	input              clk,
	input              rst,

	// command FIFO (show-ahead): {write, ddr address, byte enables, data}
	input      [101:0] cmd_rdata,
	input              cmd_rempty,
	output             cmd_re,

	// response FIFO
	output reg         rsp_we,
	output reg  [63:0] rsp_wdata,
	input        [3:0] rsp_wlevel,

	// Avalon-MM master
	output reg  [28:0] avm_address,
	output reg   [7:0] avm_burstcount,
	output reg         avm_read,
	output reg         avm_write,
	output reg  [63:0] avm_writedata,
	output reg   [7:0] avm_byteenable,
	input              avm_waitrequest,
	input       [63:0] avm_readdata,
	input              avm_readdatavalid
);

wire        c_write = cmd_rdata[101];
wire [28:0] c_addr  = cmd_rdata[100:72];
wire  [7:0] c_be    = cmd_rdata[71:64];
wire [63:0] c_data  = cmd_rdata[63:0];

localparam B_IDLE = 2'd0, B_CMD = 2'd1, B_DATA = 2'd2;
reg [1:0] bst;
reg       rd_act;             // a read command is presented or accepted
reg [1:0] rcv;                // its beats received so far

// a command is taken when idle and, for a read, the response FIFO can hold it
wire take = (bst == B_IDLE) && !cmd_rempty && (c_write || rsp_wlevel <= 4'd6);
assign cmd_re = take;
wire beat = avm_readdatavalid && rd_act;

always @(posedge clk) begin
	rsp_we <= 1'b0;
	if (rst) begin
		bst <= B_IDLE;
		avm_read <= 1'b0; avm_write <= 1'b0; rd_act <= 1'b0; rcv <= 2'd0;
	end else begin
		// read data: qualified by readdatavalid alone
		if (beat) begin
			rsp_we    <= 1'b1;
			rsp_wdata <= avm_readdata;
			rcv       <= rcv + 2'd1;
		end
		case (bst)
			B_IDLE: if (take) begin
				avm_address    <= c_addr;
				avm_byteenable <= c_write ? c_be : 8'hFF;
				avm_writedata  <= c_data;
				avm_burstcount <= c_write ? 8'd1 : 8'd2;
				avm_write      <= c_write;
				avm_read       <= !c_write;
				rd_act         <= !c_write;
				rcv            <= 2'd0;
				bst <= B_CMD;
			end
			B_CMD: if (!avm_waitrequest) begin
				// the command is accepted
				avm_read <= 1'b0; avm_write <= 1'b0;
				bst <= avm_write ? B_IDLE : B_DATA;
			end
			default: begin
				// both beats of the line are in
				if (rcv + (beat ? 2'd1 : 2'd0) == 2'd2) begin
					rd_act <= 1'b0;
					bst <= B_IDLE;
				end
			end
		endcase
	end
end

initial begin
	bst = B_IDLE; rd_act = 1'b0; rcv = 2'd0; rsp_we = 1'b0; rsp_wdata = 64'd0;
	avm_address = 29'd0; avm_burstcount = 8'd1; avm_read = 1'b0; avm_write = 1'b0;
	avm_writedata = 64'd0; avm_byteenable = 8'd0;
end

endmodule
