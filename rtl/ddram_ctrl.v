//////////////////////////////////////////////////////////////////////////////
//////////////////////////////////////////////////////////////////////////////
//                                                                          //
// DDR3 memory interface                                                    // 
// Copyright (c)2019 Alexey Melnikov                                        //
// Based on SDRAM controller by Tobias Gubener                              //
//                                                                          //
// This source file is free software: you can redistribute it and/or modify //
// it under the terms of the GNU General Public License as published        //
// by the Free Software Foundation, either version 3 of the License, or     //
// (at your option) any later version.                                      //
//                                                                          //
// This source file is distributed in the hope that it will be useful,      //
// but WITHOUT ANY WARRANTY; without even the implied warranty of           //
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the            //
// GNU General Public License for more details.                             //
//                                                                          //
// You should have received a copy of the GNU General Public License        //
// along with this program.  If not, see <http://www.gnu.org/licenses/>.    //
//                                                                          //
//////////////////////////////////////////////////////////////////////////////


module ddram_ctrl
(
	// system
	input             sysclk,
	input             reset_n,
	input             cache_rst,
	input             cache_inhibit,
	input       [3:0] cpu_cache_ctrl,

	// DDR3    
	output            DDRAM_CLK,
	input             DDRAM_BUSY,
	output      [7:0] DDRAM_BURSTCNT,
	output reg [28:0] DDRAM_ADDR,
	input      [63:0] DDRAM_DOUT,
	input             DDRAM_DOUT_READY,
	output reg        DDRAM_RD,
	output reg [63:0] DDRAM_DIN,
	output reg  [7:0] DDRAM_BE,
	output reg        DDRAM_WE,

	// cpu    
	input      [28:1] cpuAddr,
	input             cpuCS,
	input       [1:0] cpustate,
	input             cpuL,
	input             cpuU,
	input      [15:0] cpuWR,
	output     [15:0] cpuRD,
	input             ramshared,
	output            ramready
);

wire ramsel = cpuCS & (~&cpustate | ~cpuU | ~cpuL);

// cpu_cache_new treats cpu_cs as a level and holds its read acknowledgement
// until cpu_cs drops. TG68 can advance directly from a completed read to a
// write while the outer RAM select remains asserted. Detect a changed bus
// transaction and force one cache-clock edge with cpu_cs low; this returns the
// cache state machine to IDLE before exposing the new transaction. Keep the
// payload live: write data is not guaranteed valid on the first ramsel edge.
reg  [28:1] cacheReqAddr;
reg  [15:0] cacheReqDat;
reg         cacheReqU, cacheReqL;
reg   [1:0] cacheReqState;
reg         cacheReqActive;
wire cache_request_matches = cacheReqActive &&
                             (cpuAddr == cacheReqAddr) &&
                             (cpuU == cacheReqU) && (cpuL == cacheReqL) &&
                             (cpustate == cacheReqState) &&
                             ((cpustate != 2'b11) || (cpuWR == cacheReqDat));
wire cache_cpu_cs = ramsel && cache_request_matches;
always @(posedge sysclk) begin
	if (~reset_n) begin
		cacheReqActive <= 0;
		cacheReqAddr <= 0;
		cacheReqDat <= 0;
		cacheReqU <= 1;
		cacheReqL <= 1;
		cacheReqState <= 1;
	end else if (!ramsel) begin
		cacheReqActive <= 0;
	end else if (!cache_request_matches) begin
		cacheReqAddr <= cpuAddr;
		cacheReqDat <= cpuWR;
		cacheReqU <= cpuU;
		cacheReqL <= cpuL;
		cacheReqState <= cpustate;
		cacheReqActive <= 1;
	end
end

wire cache_hit;
wire cache_req;
reg  cache_fill;
wire cache_ack;
reg        ddr_swap;
reg [15:0] ddr_data;

// Write snoop pulse (cache coherence for inhibited/bypassed writes).
reg        snoop_upd;
reg [28:1] snoopAddr;
reg [15:0] snoopDat;
reg  [1:0] snoopBS;

reg  [1:0] write_state;
reg  [2:0] state;
reg  [1:0] ba;
reg [63:0] dout;

// Single-entry write buffer. These declarations precede the optional ISSP
// block because that block captures both enqueue and Avalon-accept state.
reg        write_ena;
reg        write_req;
reg        write_ack;
reg  [1:0] writeBE;
reg [28:1] writeAddr;
reg [15:0] writeDat;
wire [15:0] cpu_write_dat = ramshared ? {cpuWR[7:0],cpuWR[15:8]} : cpuWR;
wire  [1:0] cpu_write_be = ramshared ? ~{cpuL, cpuU} : ~{cpuU, cpuL};
wire        write_cycle_matches = (cpustate == 2'b11) &&
                                  (cpuAddr == writeAddr) &&
                                  (cpu_write_dat == writeDat) &&
                                  (cpu_write_be == writeBE);

`ifdef ENABLE_DDRAM_DEBUG_ISSP
// Avalon-boundary trace for the NetBSD init PTE at physical $4FFF6074.
// The active 256 MB Z3_1 bank maps that line to Avalon address $07FFEC0E.
// Keep this probe in the controller: cpu_wrapper's RTWR trace is upstream of
// the write buffer and cannot prove which command the HPS DDR bridge accepted.
// Match below the bank-select bits so the same probe also works when the
// target page is allocated from Z3_0 in a smaller Fast RAM configuration.
localparam [24:0] DDRW_TARGET_LINE = 25'h1FFEC0E;
localparam [24:0] DDRW_PRIOR_TARGET_LINE = 25'h1F7FC5E;
wire ddrw_target_addr = (DDRAM_ADDR[24:0] == DDRW_TARGET_LINE) ||
                        (DDRAM_ADDR[24:0] == DDRW_PRIOR_TARGET_LINE);
wire ddrw_write_accept = DDRAM_WE && !DDRAM_BUSY && ddrw_target_addr;
wire ddrw_read_accept = DDRAM_RD && !DDRAM_BUSY && ddrw_target_addr;
wire [0:0] ddrw_issp_source;

reg        ddrw_write_seen;
reg [15:0] ddrw_write_count;
reg [28:0] ddrw_write_addr;
reg [63:0] ddrw_write_din;
reg  [7:0] ddrw_write_be;
reg [28:1] ddrw_write_cpu_addr;
reg [15:0] ddrw_write_dat;
reg  [1:0] ddrw_write_src_be;
reg        ddrw_write_cache_inhibit;
reg  [1:0] ddrw_write_cpustate;
reg  [1:0] ddrw_write_buffer_state;
reg  [2:0] ddrw_write_ddr_state;
reg  [7:0] ddrw_write_be_seen;
reg [63:0] ddrw_write_line_image;

reg        ddrw_read_seen;
reg [15:0] ddrw_read_count;
reg [28:0] ddrw_read_addr;
reg [28:1] ddrw_read_cpu_addr;
reg  [1:0] ddrw_read_ba;
reg        ddrw_read_cache_inhibit;
reg  [1:0] ddrw_read_cpustate;
reg  [2:0] ddrw_read_ddr_state;

reg        ddrw_return_seen;
reg [15:0] ddrw_return_count;
reg [63:0] ddrw_return_dout;
reg  [1:0] ddrw_return_ba;
reg        ddrw_zero_return_seen;
reg [63:0] ddrw_zero_return_dout;
reg  [1:0] ddrw_zero_return_ba;
reg        ddrw_target_read_pending;
integer ddrw_lane;

always @(posedge sysclk) begin
	if (!reset_n || ddrw_issp_source[0]) begin
		ddrw_write_seen <= 0;
		ddrw_write_count <= 0;
		ddrw_write_addr <= 0;
		ddrw_write_din <= 0;
		ddrw_write_be <= 0;
		ddrw_write_cpu_addr <= 0;
		ddrw_write_dat <= 0;
		ddrw_write_src_be <= 0;
		ddrw_write_cache_inhibit <= 0;
		ddrw_write_cpustate <= 0;
		ddrw_write_buffer_state <= 0;
		ddrw_write_ddr_state <= 0;
		ddrw_write_be_seen <= 0;
		ddrw_write_line_image <= 0;
		ddrw_read_seen <= 0;
		ddrw_read_count <= 0;
		ddrw_read_addr <= 0;
		ddrw_read_cpu_addr <= 0;
		ddrw_read_ba <= 0;
		ddrw_read_cache_inhibit <= 0;
		ddrw_read_cpustate <= 0;
		ddrw_read_ddr_state <= 0;
		ddrw_return_seen <= 0;
		ddrw_return_count <= 0;
		ddrw_return_dout <= 0;
		ddrw_return_ba <= 0;
		ddrw_zero_return_seen <= 0;
		ddrw_zero_return_dout <= 0;
		ddrw_zero_return_ba <= 0;
		ddrw_target_read_pending <= 0;
	end else begin
		if (ddrw_write_accept) begin
			ddrw_write_seen <= 1;
			if (ddrw_write_count != 16'hFFFF)
				ddrw_write_count <= ddrw_write_count + 16'd1;
			ddrw_write_addr <= DDRAM_ADDR;
			ddrw_write_din <= DDRAM_DIN;
			ddrw_write_be <= DDRAM_BE;
			ddrw_write_cpu_addr <= writeAddr;
			ddrw_write_dat <= writeDat;
			ddrw_write_src_be <= writeBE;
			ddrw_write_cache_inhibit <= cache_inhibit;
			ddrw_write_cpustate <= cpustate;
			ddrw_write_buffer_state <= write_state;
			ddrw_write_ddr_state <= state;
			ddrw_write_be_seen <= ddrw_write_be_seen | DDRAM_BE;
			for (ddrw_lane = 0; ddrw_lane < 8; ddrw_lane = ddrw_lane + 1)
				if (DDRAM_BE[ddrw_lane])
					ddrw_write_line_image[ddrw_lane*8 +: 8] <=
						DDRAM_DIN[ddrw_lane*8 +: 8];
		end

		if (ddrw_read_accept) begin
			ddrw_read_seen <= 1;
			if (ddrw_read_count != 16'hFFFF)
				ddrw_read_count <= ddrw_read_count + 16'd1;
			ddrw_read_addr <= DDRAM_ADDR;
			ddrw_read_cpu_addr <= cpuAddr;
			ddrw_read_ba <= ba;
			ddrw_read_cache_inhibit <= cache_inhibit;
			ddrw_read_cpustate <= cpustate;
			ddrw_read_ddr_state <= state;
			ddrw_target_read_pending <= 1;
		end

		if (DDRAM_DOUT_READY && ddrw_target_read_pending) begin
			ddrw_return_seen <= 1;
			if (ddrw_return_count != 16'hFFFF)
				ddrw_return_count <= ddrw_return_count + 16'd1;
			ddrw_return_dout <= DDRAM_DOUT;
			ddrw_return_ba <= ba;
			ddrw_target_read_pending <= 0;
			if (DDRAM_DOUT == 64'd0) begin
				ddrw_zero_return_seen <= 1;
				ddrw_zero_return_dout <= DDRAM_DOUT;
				ddrw_zero_return_ba <= ba;
			end
		end
	end
end

// 496 probe bits. Source bit 0 synchronously clears the sticky capture.
altsource_probe #(
	.probe_width(496),
	.source_width(1),
	.instance_id("DDRW")
) ddrw_issp (
	.probe({
		ddrw_write_seen,
		ddrw_write_count,
		ddrw_write_addr,
		ddrw_write_din,
		ddrw_write_be,
		ddrw_write_cpu_addr,
		ddrw_write_dat,
		ddrw_write_src_be,
		ddrw_write_cache_inhibit,
		ddrw_write_cpustate,
		ddrw_write_buffer_state,
		ddrw_write_ddr_state,
		ddrw_write_be_seen,
		ddrw_write_line_image,
		ddrw_read_seen,
		ddrw_read_count,
		ddrw_read_addr,
		ddrw_read_cpu_addr,
		ddrw_read_ba,
		ddrw_read_cache_inhibit,
		ddrw_read_cpustate,
		ddrw_read_ddr_state,
		ddrw_return_seen,
		ddrw_return_count,
		ddrw_return_dout,
		ddrw_return_ba,
		ddrw_zero_return_seen,
		ddrw_zero_return_dout,
		ddrw_zero_return_ba,
		ddrw_target_read_pending,
		cacheReqActive,
		cache_cpu_cs,
		cache_req,
		cache_fill,
		write_req,
		write_ack,
		write_ena,
		DDRAM_BUSY,
		DDRAM_DOUT_READY,
		DDRAM_WE,
		DDRAM_RD,
		state,
		write_state,
		cpustate,
		ramready
	}),
	.source(ddrw_issp_source)
);
`endif

cpu_cache_new cpu_cache
(
	.clk              (sysclk),                 // clock
	.rst              (~reset_n | ~cache_rst),  // cache reset
	.cpu_cache_ctrl   (cpu_cache_ctrl),         // CPU cache control
	.cache_inhibit    (cache_inhibit | ramshared), // cache inhibit
	.cpu_cs           (cache_cpu_cs),           // distinct cpu transactions
	.cpu_adr          (cpuAddr),                // live cpu address
	.cpu_bs           (~{cpuU, cpuL}),          // cpu byte selects
	.cpu_we           (cpustate == 3),          // cpu write
	.cpu_ir           (cpustate == 0),          // cpu instruction read
	.cpu_dr           (cpustate == 2),          // cpu data read
	.cpu_dat_w        (cpuWR),                  // live cpu write data
	.cpu_dat_r        (cpuRD),                  // cpu read data
	.cpu_ack          (cache_hit),              // cpu acknowledge
	.wb_en            (cache_ack),              // write enable
	.sdr_dat_r        (ddr_swap ? {ddr_data[7:0], ddr_data[15:8]} : ddr_data), // sdram read data
	.sdr_read_req     (cache_req),              // sdram read request from cache
	.sdr_read_ack     (cache_fill),             // sdram read acknowledge to cache
	// Snoop-update the cache on EVERY accepted CPU write. Writes issued with
	// cache_inhibit high (the inhibit term includes walker_active, so a store
	// whose translation needs a page-table walk - e.g. the M-bit rewalk on a
	// freshly mapped kernel stack - bypasses the normal cpu_we update) still
	// reached DDR but left a matching cache line STALE: subsequent reads hit
	// the line and return pre-fill zeros with a clean ack (NetBSD fork
	// trapframe popped as zero while the fill was acked at the correct
	// physical page - beacon 0010 capture). The snoop port updates existing
	// lines only, so snooping every write is idempotent with the normal path.
	.snoop_act        (snoop_upd),
	.snoop_adr        (snoopAddr),
	.snoop_dat_w      (snoopDat),
	.snoop_bs         (snoopBS)
);

// write buffer, enables CPU to continue while a write is in progress

	always @ (posedge sysclk) begin
		if(~reset_n) begin
			write_req   <= 0;
			write_ena   <= 0;
			write_state <= 0;
			snoop_upd   <= 0;
			snoopAddr   <= 0;
			snoopDat    <= 0;
			snoopBS     <= 0;
		end else begin
			write_ena <= 0;
			snoop_upd <= 0;
			case(write_state)
				default:
					if(cache_cpu_cs && cpustate == 3) begin
						writeAddr <= cpuAddr;
						writeDat  <= cpu_write_dat;
						writeBE   <= cpu_write_be;
						write_req <= 1;
						if(cache_ack) begin
							write_state <= 1;
							snoop_upd <= 1;
							snoopAddr <= cpuAddr;
							snoopDat  <= cpuWR;
							snoopBS   <= ~{cpuU, cpuL};
						end
					end

				1: if(write_ack) begin
						// The DDR controller has picked up the request; only now
						// acknowledge the CPU so back-to-back writes cannot
						// outrun the single-entry write buffer.
						write_ena   <= 1;
						write_req   <= 0;
						write_state <= 2;
					end

				2: begin
						// sysclk is 114 MHz while TG68 samples ramready at 28 MHz.
						// Hold completion until the CPU advances this exact bus cycle;
						// a one-sysclk pulse can fall entirely between CPU edges.
						if (write_cycle_matches)
							write_ena <= 1;
						else if (!write_ack)
							write_state <= 0;
					end
			endcase
	end
end

// A held read acknowledgement must never complete a following write. Writes
// retire only after the physical DDR command has been accepted.
assign ramready = (cpustate == 2'b11) ? write_ena : cache_hit;

assign DDRAM_CLK = sysclk;
assign DDRAM_BURSTCNT = 1;

always @ (posedge sysclk) begin
	cache_fill <= 0;
	ddr_data <= dout[{ba, 4'b0000} +:16];

	if(~reset_n) begin
		state     <= 0;
		write_ack <= 0;
		ba        <= 0;
		dout      <= 0;
		ddr_swap  <= 0;
		ddr_data  <= 0;
		DDRAM_WE  <= 0;
		DDRAM_RD  <= 0;
	end
	else begin
		// Avalon-MM accepts a command only on an edge where the request is
		// asserted and waitrequest is low. Keep the request asserted until that
		// edge; checking DDRAM_BUSY before launching it is insufficient because
		// waitrequest may change before DDRAM_WE/DDRAM_RD is sampled.
		if (DDRAM_WE && !DDRAM_BUSY) begin
			DDRAM_WE  <= 0;
			write_ack <= 1;
		end
		if (DDRAM_RD && !DDRAM_BUSY)
			DDRAM_RD <= 0;

		case(state)
			0: if(!DDRAM_BUSY && !DDRAM_WE && !DDRAM_RD) begin
					if(~write_ack & write_req) begin
						DDRAM_ADDR <= {3'b001, writeAddr[28:3]};
						DDRAM_BE   <= {6'b000000,writeBE}<<{writeAddr[2:1],1'b0};
						DDRAM_DIN  <= {writeDat,writeDat,writeDat,writeDat};
						DDRAM_WE   <= 1;
					end
					else if(cache_req) begin
						DDRAM_ADDR <= {3'b001, cpuAddr[28:3]};
						DDRAM_BE   <= 8'hFF;
						DDRAM_RD   <= 1;
						ba         <= cpuAddr[2:1];
						state      <= 1;
						ddr_swap   <= ramshared;
					end
				end
			1: if(DDRAM_DOUT_READY) begin
					ddr_data      <= DDRAM_DOUT[{ba, 4'b0000} +:16];
					dout          <= DDRAM_DOUT;
					cache_fill    <= 1;
					ba            <= ba + 1'd1;
					state         <= state + 1'd1;
				end
			2,3: begin
					cache_fill    <= 1;
					ba            <= ba + 1'd1;
					state         <= state + 1'd1;
				end
			4: begin
					cache_fill    <= 1;
					state         <= 0;
				end
		endcase

		if(~write_req && !DDRAM_WE) write_ack <= 0;
	end
end

endmodule
