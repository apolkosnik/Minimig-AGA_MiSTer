//
// hps_ext for Minimig
//
// Copyright (c) 2020 Alexey Melnikov
//
// This source file is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This source file is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.
//
///////////////////////////////////////////////////////////////////////

module hps_ext
(
	input             clk_sys,
	inout      [35:0] EXT_BUS,

	output            io_strobe,
	output            io_fpga,
	output            io_uio,
	output     [15:0] io_din,
	input      [15:0] fpga_dout,

	input      [15:0] ide_din,
	output reg [15:0] ide_dout,
	output reg  [4:0] ide_addr,
	output reg        ide_rd,
	output reg        ide_wr,
	input       [5:0] ide_req,

	// NE2000 Ethernet interface
	input      [31:0] eth_status,
	input       [7:0] eth_tx_data,
	output reg        eth_tx_rd_strobe,
	output reg        eth_tx_begin,
	output reg  [7:0] eth_rx_data,
	output reg        eth_rx_wr_strobe,
	output reg        eth_rx_begin,
	output reg  [7:0] eth_mac_data,
	output reg        eth_mac_strobe,
	output reg        eth_mac_begin,

	output reg  [2:0] mouse_buttons,
	output reg        kbd_mouse_level,
	output reg  [1:0] kbd_mouse_type,
	output reg  [7:0] kbd_mouse_data,

	input      [11:0] scr_hbl_l,
	input      [11:0] scr_hbl_r,
	input      [11:0] scr_hsize,
	input      [11:0] scr_vbl_t,
	input      [11:0] scr_vbl_b,
	input      [11:0] scr_vsize,
	input       [6:0] scr_flg,
	input       [1:0] scr_res,

	output reg [11:0] shbl_l,
	output reg [11:0] shbl_r,
	output reg [11:0] svbl_t,
	output reg [11:0] svbl_b,
	output reg        sset,

	input             cdda_req,
	output reg        cdda_wr,
	output reg [15:0] cdda_dout
);

assign EXT_BUS[15:0] = io_fpga ? fpga_dout : io_dout;
assign io_din = EXT_BUS[31:16];
assign EXT_BUS[32] = dout_en | io_fpga;
assign io_strobe = EXT_BUS[33];
assign io_uio = EXT_BUS[34];
assign io_fpga = EXT_BUS[35];

localparam EXT_CMD_MIN  = UIO_GET_VMODE;
localparam EXT_CMD_MAX  = UIO_SET_VPOS;
localparam EXT_CMD_MIN2 = 'h61;
localparam EXT_CMD_MAX2 = 'h64;

localparam UIO_MOUSE     = 'h04;
localparam UIO_KEYBOARD  = 'h05;
localparam UIO_KBD_OSD   = 'h06;
localparam UIO_GET_VMODE = 'h2C;
localparam UIO_SET_VPOS  = 'h2D;

reg [15:0] io_dout;
reg        dout_en;
reg  [4:0] byte_cnt;

always@(posedge clk_sys) begin
	reg [15:0] cmd;
	reg ide_cs = 0;
	reg cdda_cs = 0;
	reg eth_cs = 0;
	reg [1:0] eth_mode = 0; // 0=TX read, 1=RX write, 2=MAC write, 3=status read

	sset <= 0;

	{ide_rd, ide_wr} <= 0;
	cdda_wr <= 0;
	{eth_tx_rd_strobe, eth_rx_wr_strobe, eth_mac_strobe} <= 0;
	if((ide_rd | ide_wr) & ~&ide_addr[3:0]) ide_addr <= ide_addr + 1'd1;

	if(~io_uio) begin
		dout_en <= 0;
		io_dout <= 0;
		byte_cnt <= 0;
		ide_cs <= 0;
		cdda_cs <= 0;
		eth_cs <= 0;
		eth_tx_begin <= 0;
		eth_rx_begin <= 0;
		eth_mac_begin <= 0;
		if(cmd == 'h2D) sset <= 1;
	end
	else if(io_strobe) begin

		io_dout <= 0;
		if(~&byte_cnt) byte_cnt <= byte_cnt + 1'd1;

		ide_dout <= io_din;
		cdda_dout <= io_din;
		eth_rx_data <= io_din[7:0];
		eth_mac_data <= io_din[7:0];
		if(byte_cnt == 1) begin
			ide_addr <= {io_din[8],io_din[3:0]};
			ide_cs   <= (io_din[15:9] == 7'b1111000);  // 0xF0xx - IDE
			cdda_cs  <= (io_din[15:9] == 7'b1111001);  // 0xF2xx - CDDA
			eth_cs   <= (io_din[15:9] == 7'b1111010);  // 0xF4xx - Ethernet
			eth_mode <= io_din[1:0];  // Lower 2 bits select mode: 0=TX, 1=RX, 2=MAC, 3=status
		end

		if(byte_cnt == 0) begin
			cmd <= io_din;
			dout_en <= (io_din >= EXT_CMD_MIN && io_din <= EXT_CMD_MAX) || (io_din >= EXT_CMD_MIN2 && io_din <= EXT_CMD_MAX2);
			if(io_din == 'h63) begin
				io_dout <= {4'hE, 2'b00, 1'b0, cdda_req, 2'b00, ide_req};
			end
			if(io_din == 'h64) begin
				// Return ethernet status word (32-bit, sent as 2x16-bit)
				io_dout <= eth_status[31:16];
			end
		end else begin
			case(cmd)
			
				UIO_MOUSE:
					case(byte_cnt)
						1: begin
								kbd_mouse_data <= io_din[7:0];
								kbd_mouse_type <= 0;
								kbd_mouse_level <= ~kbd_mouse_level;
							end
						2: begin
								// second byte contains movement data
								kbd_mouse_data <= io_din[7:0];
								kbd_mouse_type <= 1;
								kbd_mouse_level <= ~kbd_mouse_level; 
							end
						3: begin
								// third byte contains the buttons
								mouse_buttons <= io_din[2:0];
							end
						4: begin
								// wheel
								kbd_mouse_data <= io_din[7:0];
								kbd_mouse_level <= ~kbd_mouse_level; 
							end
					endcase

				UIO_KEYBOARD:
					if(byte_cnt == 1) begin
						kbd_mouse_data <= io_din[7:0];
						kbd_mouse_type <= 2;
						kbd_mouse_level <= ~kbd_mouse_level;
					end

				UIO_KBD_OSD:
					if(byte_cnt == 1) begin
						kbd_mouse_data <= io_din[7:0];
						kbd_mouse_type <= 3;
						kbd_mouse_level <= ~kbd_mouse_level;
					end

				UIO_GET_VMODE:
					case(byte_cnt)
						1: io_dout <= {1'b1, scr_flg, 6'd0, scr_res};
						2: io_dout <= scr_hsize;
						3: io_dout <= scr_vsize;
						4: io_dout <= scr_hbl_l;
						5: io_dout <= scr_hbl_r;
						6: io_dout <= scr_vbl_t;
						7: io_dout <= scr_vbl_b;
					endcase

				UIO_SET_VPOS:
					case(byte_cnt)
						1: shbl_l <= io_din[11:0];
						2: shbl_r <= io_din[11:0];
						3: svbl_t <= io_din[11:0];
						4: svbl_b <= io_din[11:0];
					endcase
					
				'h61: begin
					if(byte_cnt >= 3) begin
						cdda_wr <= cdda_cs;
						ide_wr  <= ide_cs;
					end
				end

				'h62: if(byte_cnt >= 3 && ide_cs) begin
							io_dout <= ide_din;
							ide_rd <= 1;
						end

				'h64: begin
					// Ethernet operations
					case(byte_cnt)
						1: begin
							// Return lower 16 bits of status on second byte
							io_dout <= eth_status[15:0];
						end

						2: begin
							// Start transfer on byte 2
							if(eth_cs) begin
								case(eth_mode)
									2'b00: eth_tx_begin <= 1;  // TX read mode
									2'b01: eth_rx_begin <= 1;  // RX write mode
									2'b10: eth_mac_begin <= 1; // MAC write mode
								endcase
							end
						end

						default: begin
							// Data transfer starts at byte 3+
							if(eth_cs && byte_cnt >= 3) begin
								case(eth_mode)
									2'b00: begin
										// TX read: ARM reads from FPGA TX buffer
										io_dout <= {8'h00, eth_tx_data};
										eth_tx_rd_strobe <= 1;
									end

									2'b01: begin
										// RX write: ARM writes to FPGA RX buffer
										eth_rx_wr_strobe <= 1;
									end

									2'b10: begin
										// MAC write: ARM writes MAC address (6 bytes)
										eth_mac_strobe <= 1;
									end
								endcase
							end
						end
					endcase
				end
			endcase
		end
	end
end

endmodule
