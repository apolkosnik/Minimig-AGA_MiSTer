//--------------------------------------------------------------------------//
//--------------------------------------------------------------------------//
//                                                                          //
// Copyright (c) 2009-2011 Tobias Gubener                                   //
// Copyright (c) 2017-2019 Alexey Melnikov                                  //
// Subdesign fAMpIGA by TobiFlex                                            //
//                                                                          //
// This is the cpu wrapper to generate 68K Bus signals                      //
// and configure Zorro cards                                                //
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
//--------------------------------------------------------------------------//
//--------------------------------------------------------------------------//

module cpu_wrapper
(
	input             reset,
	output reg        reset_out,

	input             clk,
	input             ph1,
	input             ph2,

	input       [1:0] cpucfg,
	input       [2:0] fastramcfg,
	input       [2:0] cachecfg,
	input             bootrom,

	output reg [23:1] chip_addr,
	input      [15:0] chip_dout,
	output reg [15:0] chip_din,
	output reg        chip_as,
	output reg        chip_uds,
	output reg        chip_lds,
	output reg        chip_rw,
	input             chip_dtack,
	input       [2:0] chip_ipl,
	
	input      [15:0] fastchip_dout,
	output reg        fastchip_sel,
	output            fastchip_lds,
	output            fastchip_uds,
	output            fastchip_rnw,
	output reg        fastchip_lw,
	input             fastchip_selack,
	input             fastchip_ready,

	output            ramsel,
	output     [28:1] ramaddr,
	output     [15:0] ramdin,
	input      [15:0] ramdout,
	input             ramready,
	output            ramlds,
	output            ramuds,
	output            ramshared,

	output            toccata_ena,
	output reg  [7:0] toccata_base,

	output reg  [1:0] cpustate,
	output reg  [3:0] cacr,
	output reg [31:0] nmi_addr
);

assign ramsel       = cpu_req & ~sel_nmi_vector & (sel_zram | sel_chipram | sel_kickram | sel_dd | sel_rtg);
assign ramshared    = sel_dd;

// NMI
always @(posedge clk) nmi_addr <= vbr + 32'h7c;

wire sel_z3ram0 = (cpu_addr[31:27] == z3ram_base0) && z3ram_ena0;
wire sel_z3ram1 = (cpu_addr[31:28] == z3ram_base1) && z3ram_ena1;
wire sel_z2ram  = !cpu_addr[31:24] && (cpu_addr[23] ^ |cpu_addr[22:21]) && z2ram_ena; // addr[23:21] = 1..4
wire sel_zram   = sel_z3ram0 | sel_z3ram1 | sel_z2ram;
wire sel_dd     = (cpu_addr[31:16] == 16'h00DD) && (cpu_addr[15:13] == 'b010);
wire sel_rtg    = (cpu_addr[31:24] == 8'h02);

// don't sel_kickram when writing
wire sel_kickram   = !cpu_addr[31:24] && (&cpu_addr[23:19] || (cpu_addr[23:19] == 5'b11100)) && ckick && wr;	// $f8xxxx, e0xxxx
wire sel_kicklower = !cpu_addr[31:24] && (cpu_addr[23:18] == 6'b111110);
wire sel_chipram   = !cpu_addr[31:21] && cchip; 		             //$000000 - $1FFFFF

// we route everything hrtmon related through cart.v (needs a couple of signals to
// decide what to do, would not be good style to replicate that here). 
wire sel_nmi_vector = (cpu_addr[31:2] == nmi_addr[31:2]) && (cpustate == 2);

wire [15:0] ramdat;

assign ramlds = sel_rtg ? uds_in : lds_in;
assign ramuds = sel_rtg ? lds_in : uds_in;
assign ramdin = sel_rtg ? {cpu_dout[7:0],cpu_dout[15:8]} : cpu_dout;
assign ramdat = sel_rtg ? {ramdout[7:0], ramdout[15:8]}  : ramdout;

//       Main  DDx  RTG  8M  128M  256M
//       ----  ---  ---  --  ----  ----
//        SDR  DDR  RTG  Z2  Z3_0  Z3_1
// 28      0    0    0   1    0     1
// 27      0    0    0   1    1     X
// 26      0    1    1   0    X     X
// 25-23   0   111  110  0    X     X
// supported configs: SDR + (Z2, Z3_1, Z3_0+Z3_1)

// This is the mapping to the sram
// map 00-1f to 00-1f (chipram), a0-ff to 20-7f. All non-fastram goes into the first
// 8M block(SDRAM). This map should be the same as in minimig_sram_bridge.v 
// All Zorro RAM goes to DDR3
assign ramaddr[28]    = sel_zram & ~sel_z3ram0;
assign ramaddr[27]    = sel_zram & (~sel_z3ram1 | cpu_addr[27]);
assign ramaddr[26:23] = (sel_z3ram0 | sel_z3ram1) ? cpu_addr[26:23]: (sel_rtg ? 4'b1110 : {4{sel_dd}});
assign ramaddr[22:19] = {4{sel_dd}} | cpu_addr[22:19];
assign ramaddr[18]    =    sel_dd   | (sel_kicklower & bootrom) | cpu_addr[18];
assign ramaddr[17:16] = {2{sel_dd}} | cpu_addr[17:16];
assign ramaddr[15:1]  = cpu_addr[15:1];

assign fastchip_lds = lds_in;
assign fastchip_uds = uds_in;
assign fastchip_rnw = wr;

reg  [31:0] cpu_addr;
reg  [15:0] cpu_dout;
wire [15:0] cpu_din = ramsel ? ramdat : fastchip_selack ? fastchip_dout : {sel_autoconfig ? autocfg_data : chip_data[15:12], chip_data[11:0]};
reg         wr;
reg         uds_in;
reg         lds_in;
reg  [15:0] chip_data;
reg  [31:0] vbr;

//========================================
// MC68030 F-line MMU instruction support
//========================================

// F-line interface signals
wire fline_is_mmu;
wire fline_is_pmove;
wire fline_is_pflush;
wire fline_is_ptest;
wire fline_exec_req;
reg  fline_exec_done;

// Opcode capture
reg [15:0] fline_opcode;
reg [15:0] fline_extension;
reg fline_opcode_valid;

// Supervisor mode detection
wire cpu_supervisor = (cpustate_p == 2'b01);

always @* begin
	if(cpucfg[1:0]) begin
		cpu_dout     = cpu_dout_p;
		cpu_addr     = cpu_addr_p;
		cpustate     = cpustate_p;
		cacr         = cacr_p;
		vbr          = vbr_p;
		wr           = wr_p;
		uds_in       = uds_p;
		lds_in       = lds_p;
		reset_out    = reset_out_p;
		chip_as      = c_as;
		chip_rw      = c_rw;
		chip_uds     = c_uds;
		chip_lds     = c_lds;
		chip_addr    = cpu_addr_p[23:1];
		chip_din     = cpu_dout_p;
		chip_data    = chipdout_i;
		fastchip_sel = cpu_req & !cpu_addr_p[31:24];
		fastchip_lw  = longword;
	end
	else begin
		cpu_dout     = cpu_dout_o;
		cpu_addr     = {cpu_addr_o,1'b0};
		cpustate     = as_o ? 2'b01 : ~{wr_o,wr_o};
		cacr         = 1;
		vbr          = 0;
		wr           = wr_o;
		uds_in       = uds_o;
		lds_in       = lds_o;
		reset_out    = reset_out_o;
		chip_as      = ramsel | as_o;
		chip_rw      = wr_o;
		chip_uds     = uds_o;
		chip_lds     = lds_o;
		chip_addr    = cpu_addr_o[23:1];
		chip_din     = cpu_dout_o;
		chip_data    = chip_dout;
		fastchip_sel = 0;
		fastchip_lw  = 0;
	end
end

wire [15:0] cpu_dout_p;
wire [31:0] cpu_addr_p;
wire  [1:0] cpustate_p;
wire  [3:0] cacr_p;
wire [31:0] vbr_p;
wire        wr_p;
wire        uds_p;
wire        lds_p;
wire        reset_out_p;
wire        longword;

TG68KdotC_Kernel
#(
	.sr_read(2),        // 0=>user,   1=>privileged,    2=>switchable with CPU(0)
	.vbr_stackframe(2), // 0=>no,     1=>yes/extended,  2=>switchable with CPU(0)
	.extaddr_mode(2),   // 0=>no,     1=>yes,           2=>switchable with CPU(1)
	.mul_mode(2),       // 0=>16Bit,  1=>32Bit,         2=>switchable with CPU(1),  3=>no MUL,
	.div_mode(2),       // 0=>16Bit,  1=>32Bit,         2=>switchable with CPU(1),  3=>no DIV,
	.bitfield(2)        // 0=>no,     1=>yes,           2=>switchable with CPU(1)
)
cpu_inst_p
(
  .clk(clk),
  .nreset(reset),
  .clkena_in(~cpu_req | chipready | ramready | fastchip_ready),
  .data_in(cpu_din),
  .ipl(cpu_ipl),
  .ipl_autovector(1),
  .regin_out(),
  .addr_out(cpu_addr_p),
  .data_write(cpu_dout_p),
  .nwr(wr_p),
  .nuds(uds_p),
  .nlds(lds_p),
  .nresetout(reset_out_p),
  .longword(longword),
  
  .cpu(cpucfg),
  .busstate(cpustate_p),		// 0: fetch code, 1: no memaccess, 2: read data, 3: write data
  .cacr_out(cacr_p),
  .vbr_out(vbr_p),

  // MC68030 F-line interface
  .fline_is_mmu(fline_is_mmu & cpucfg[1]),
  .fline_is_pmove(fline_is_pmove & cpucfg[1]),
  .fline_is_pflush(fline_is_pflush & cpucfg[1]),
  .fline_is_ptest(fline_is_ptest & cpucfg[1]),
  .fline_exec_req(fline_exec_req),
  .fline_exec_done(fline_exec_done)
);

wire [15:0] cpu_dout_o;
wire [23:1] cpu_addr_o;
wire  [2:0] fc_o;
wire        wr_o;
wire        as_o;
wire        uds_o;
wire        lds_o;
wire        reset_out_o;

fx68k cpu_inst_o
(
	.clk(clk),
	.enPhi1(ph1),
	.enPhi2(ph2),

	.extReset(~reset),
	.pwrUp(~reset),
	.oRESETn(reset_out_o),
	.HALTn(1),

	.eRWn(wr_o),
	.ASn(as_o),
	.LDSn(lds_o),
	.UDSn(uds_o),
	.DTACKn(ramsel ? ~ramready : chip_dtack),

	.FC0(fc_o[0]),
	.FC1(fc_o[1]),
	.FC2(fc_o[2]), 

	.VPAn(~&fc_o),
	.BERRn(1),
	.BRn(1),
	.BGACKn(1),
	.IPL0n(chip_ipl[0]),
	.IPL1n(chip_ipl[1]),
	.IPL2n(chip_ipl[2]),
	.iEdb(cpu_din),
	.oEdb(cpu_dout_o),
	.eab(cpu_addr_o)
);

wire cpu_req = (cpustate != 1);

wire cchip = turbochip_d & (!cpustate | dcache_d);
wire ckick = turbokick_d & (!cpustate | dcache_d);

reg turbochip_d;
reg turbokick_d;
reg dcache_d;
always @(posedge clk) begin
	if (~reset | ~reset_out) begin
		turbochip_d <= 0;
		turbokick_d <= 0;
		dcache_d    <= 0;
	end
	else if (~cpu_req) begin	// No mem access, so safe to switch chipram access mode
		turbochip_d <= cachecfg[0] & cpucfg[1];
		turbokick_d <= cachecfg[1] & cpucfg[1];
		dcache_d    <= cachecfg[2];
	end
end

reg       chipreq;
reg [2:0] cpu_ipl;
always @(posedge clk) begin
	chipreq <= cpu_req & ~ramsel & ~fastchip_selack;
	cpu_ipl <= ipl_i;
end

reg ph1n, ph2n;
always @(posedge clk) begin
	ph1n <= ph1;
	ph2n <= ph2;
end

reg        chipready;
reg [15:0] chipdout_i;
reg  [2:0] ipl_i;
reg        c_as,c_rw,c_uds,c_lds;
always @(negedge clk, negedge reset) begin
	reg [1:0] stage;
	reg waitm;
	reg ready;

	if(~reset) begin
		stage <= 0;
		c_as <= 1;
		c_rw <= 1;
		c_uds <= 1;
		c_lds <= 1;
		ready <= 0;
	end
	else begin
		if (ph2n) begin
			waitm <= chip_dtack;
			if(~stage[0]) ipl_i <= chip_ipl;
		end

		chipready <= 0;
		if (ph1n) begin
			chipready <= ready;
			ready <= 0;
			case (stage)
				0: if (chipreq) begin
						c_as <= 0;
						c_rw <= wr;
						c_uds <= uds_in;
						c_lds <= lds_in;
						stage <= 1;
					end
				1: stage <= 2;
				2: begin
						chipdout_i <= chip_dout;
						if (~waitm) begin
							c_as <= 1;
							c_rw <= 1;
							c_uds <= 1;
							c_lds <= 1;
							ready <= 1;
							stage <= 3;
						end
					end
				3: stage <= 0;
			endcase
		end
	end
end

///////////////////// AUTOCONFIG ////////////////////////////

reg       ac_toccata;
reg [2:0] ac_memcard;
reg [3:0] autocfg_data;

always @(*) begin
	autocfg_data = 4'b1111;

	// Zorro II RAM (Up to 8 meg at 0x200000). It has a fixed base, so it must be first in the chain.
	if (~ac_memcard[2] && ac_memcard[1:0]) begin
		case (chip_addr[6:1])
			6'b000000: autocfg_data = 4'b1110;	// Zorro-II card, add mem, no ROM
			6'b000001:
				case (ac_memcard[1:0])
							1: autocfg_data = 4'b0110; // 2MB
							2: autocfg_data = 4'b0111; // 4MB
					default: autocfg_data = 4'b0000; // 8MB
				endcase
			6'b001000: autocfg_data = 4'b1110;	// Manufacturer ID: 0x139c
			6'b001001: autocfg_data = 4'b1100;
			6'b001010: autocfg_data = 4'b0110;
			6'b001011: autocfg_data = 4'b0011;
			6'b010011: autocfg_data = 4'b1110; //serial=1
			  default:;
		endcase
	end
	// Zorro II other cards
	else if(ac_toccata) begin
		case (chip_addr[6:1])
			6'h0: autocfg_data = 4'b1100; // Zorro-II card, no link, no ROM
			6'h1: autocfg_data = 4'b0001; // Next board not related, size 'h64k
			// Inverted from here on
			6'h3: autocfg_data = 4'b0011; // Lower byte product number
			//6'h5: autocfg_data = 4'b1101; // logical size 64k -- commented out -> logical size == physical size. Issue with KS1.3?
			6'h8: autocfg_data = 4'b1011; // Manufacturer ID: 0x4754
			6'h9: autocfg_data = 4'b1000;
			6'ha: autocfg_data = 4'b1010;
			6'hb: autocfg_data = 4'b1011;
			default: ;
		endcase
	end 
	// Zorro III RAM 128MB/256MB/384MB
	else if(ac_memcard[2]) begin
		case (chip_addr[6:1])
			6'b000000: autocfg_data = 4'b1010;	// Zorro-III card, add mem, no ROM
			6'b000001: autocfg_data = ac_memcard[1] ? 4'b0011 : 4'b0100; // 128MB or 256MB, extended
			6'b000010: autocfg_data = 4'b1110;	// ProductID=0x10 (only setting upper nibble)
			6'b000100: autocfg_data = 4'b0000;	// Memory card, not silenceable, Extended size, reserved.
			6'b000101: autocfg_data = 4'b1111;	// 0000 - logical size matches physical size TODO change this to 0001, so it is autosized by the OS, WHEN it will be 24MB.
			6'b001000: autocfg_data = 4'b1110;	// Manufacturer ID: 0x139c
			6'b001001: autocfg_data = 4'b1100;
			6'b001010: autocfg_data = 4'b0110;
			6'b001011: autocfg_data = 4'b0011;
			6'b010011: autocfg_data = {2'b11, ~ac_memcard[1], ac_memcard[1]};	// serial=1/2
			  default:;
		endcase
	end
end

wire sel_autoconfig = (chip_addr[23:16] == 8'b11101000) && (ac_memcard || ac_toccata); //$E80000 - $E8FFFF

reg       z2ram_ena;
reg [4:0] z3ram_base0;
reg [3:0] z3ram_base1;
reg       z3ram_ena0;
reg       z3ram_ena1;
always @(posedge clk) begin
	reg old_uds;
	old_uds <= chip_uds;

	if (~reset | ~reset_out) begin
		ac_memcard  <= cpucfg[1] ? fastramcfg : fastramcfg[2] ? 3'd3 : {1'b0, fastramcfg[1:0]};
		ac_toccata  <= 1;
		z2ram_ena   <= 0;
		z3ram_ena0  <= 0;
		z3ram_ena1  <= 0;
		z3ram_base0 <= 1;
		z3ram_base1 <= 1;
	end
	else if (sel_autoconfig && ~chip_rw && ~chip_uds && old_uds) begin
		if(~ac_memcard[2] && ac_memcard[1:0]) begin
			if (chip_addr[6:1] == 6'b100100) begin // Register 0x48 - config, ZII RAM
				z2ram_ena <= 1;
				ac_memcard <= 0;
			end
		end
		else if(ac_toccata) begin
			if (chip_addr[6:1] == 6'b100100) begin // Register 0x48 - config, Toccata card in ZII io space ($E90000)
				toccata_base <= cpu_dout[7:0];
				ac_toccata<=0;
			end		
		end
		else if(ac_memcard[2]) begin
			if(chip_addr[6:1] == 6'b100010) begin // Register 0x44, assign base address to ZIII RAM.
				if(~ac_memcard[1]) begin
					z3ram_base1 <= cpu_dout[15:12]; //256MB chunk
					z3ram_ena1 <= 1;
					ac_memcard <= {ac_memcard[0], ac_memcard[0], 1'b0};
				end
				else begin
					z3ram_base0 <= cpu_dout[15:11]; //128MB chunk
					z3ram_ena0 <= 1;
					ac_memcard <= 0;
				end
			end
		end
	end
end

assign toccata_ena = ~ac_toccata;

//========================================
// MC68030 F-line opcode capture
//========================================

always @(posedge clk) begin
	if (~reset | ~reset_out) begin
		fline_opcode <= 16'h0000;
		fline_extension <= 16'h0000;
		fline_opcode_valid <= 1'b0;
	end
	else if (cpucfg[1]) begin  // Only in 68010/68020/68030 modes
		if (cpustate == 2'b00) begin  // Instruction fetch
			fline_opcode <= cpu_dout_p;
			fline_opcode_valid <= 1'b1;
		end
		else if (fline_exec_req && fline_opcode_valid) begin
			fline_extension <= cpu_dout_p;
		end
	end
end

//========================================
// MC68030 F-line component instantiation
// Minimal integration: decoders + executors for PMOVE/PFLUSH/PTEST
//========================================

// Decoder outputs
wire pmove_is_pmove, pmove_is_pmovefd;
wire pmove_direction;
wire [7:0] pmove_reg_code;
wire [1:0] pmove_size;
wire pmove_sel_tc, pmove_sel_tt0, pmove_sel_tt1;
wire pmove_sel_crp, pmove_sel_srp, pmove_sel_mmusr;

wire pflush_is_pflush;
wire [1:0] pflush_mode;

wire ptest_is_ptest;

// Executor control
wire pmove_start, pmove_done, pmove_busy;
wire pflush_start, pflush_done, pflush_busy;
wire ptest_start, ptest_done, ptest_busy;

// MMU register interface
wire mmu_reg_read, mmu_reg_write;
wire [3:0] mmu_reg_addr;
wire [1:0] mmu_reg_size;
wire [63:0] mmu_data_in_64, mmu_data_out_64;

// Stub signals for incomplete interfaces
wire stub_mem_ready = 1'b1;
wire stub_atc_inv_ack = 1'b1;

// Combine decoder outputs
assign fline_is_pmove = pmove_is_pmove;
assign fline_is_pflush = pflush_is_pflush;
assign fline_is_ptest = ptest_is_ptest;
assign fline_is_mmu = pmove_is_pmove | pflush_is_pflush | ptest_is_ptest;

// PMOVE Decoder
TG68K030_PMOVE_Decoder pmove_decoder
(
	.clk(clk),
	.reset(~reset),
	.opcode(fline_opcode),
	.extension(fline_extension),
	.opcode_valid(fline_opcode_valid),
	.supervisor(cpu_supervisor),
	.is_pmove(pmove_is_pmove),
	.is_pmovefd(pmove_is_pmovefd),
	.pmove_direction(pmove_direction),
	.pmove_reg_code(pmove_reg_code),
	.pmove_ea_mode(),
	.pmove_ea_reg(),
	.pmove_size(pmove_size),
	.pmove_sel_tc(pmove_sel_tc),
	.pmove_sel_tt0(pmove_sel_tt0),
	.pmove_sel_tt1(pmove_sel_tt1),
	.pmove_sel_crp(pmove_sel_crp),
	.pmove_sel_srp(pmove_sel_srp),
	.pmove_sel_mmusr(pmove_sel_mmusr),
	.illegal_instr(),
	.priv_violation()
);

// PFLUSH Decoder
TG68K030_PFLUSH_Decoder pflush_decoder
(
	.clk(clk),
	.reset(~reset),
	.opcode(fline_opcode),
	.extension(fline_extension),
	.opcode_valid(fline_opcode_valid),
	.supervisor(cpu_supervisor),
	.is_pflush(pflush_is_pflush),
	.pflush_mode(pflush_mode),
	.pflush_fc(),
	.illegal_instr(),
	.priv_violation()
);

// PTEST Decoder
TG68K030_PTEST_Decoder ptest_decoder
(
	.clk(clk),
	.reset(~reset),
	.opcode(fline_opcode),
	.extension(fline_extension),
	.opcode_valid(fline_opcode_valid),
	.supervisor(cpu_supervisor),
	.is_ptest(ptest_is_ptest),
	.ptest_level(),
	.ptest_fc(),
	.ptest_rw(),
	.ptest_return_reg(),
	.illegal_instr(),
	.priv_violation()
);

// MMU Registers
TG68K030_MMU_Registers mmu_regs
(
	.clk(clk),
	.reset(~reset),
	.supervisor(cpu_supervisor),
	.reg_addr(mmu_reg_addr),
	.reg_write(mmu_reg_write),
	.reg_read(mmu_reg_read),
	.reg_size(mmu_reg_size),
	.data_in(mmu_data_out_64),
	.data_out(mmu_data_in_64),
	.tc_out(),
	.tt0_out(),
	.tt1_out(),
	.crp_out(),
	.srp_out(),
	.mmusr_out()
);

// PMOVE Executor
TG68K030_PMOVE_Execute pmove_exec
(
	.clk(clk),
	.reset(~reset),
	.pmove_start(pmove_start),
	.pmove_direction(pmove_direction),
	.pmove_fd(pmove_is_pmovefd),
	.pmove_size(pmove_size),
	.pmove_sel_tc(pmove_sel_tc),
	.pmove_sel_tt0(pmove_sel_tt0),
	.pmove_sel_tt1(pmove_sel_tt1),
	.pmove_sel_crp(pmove_sel_crp),
	.pmove_sel_srp(pmove_sel_srp),
	.pmove_sel_mmusr(pmove_sel_mmusr),
	.mem_addr(32'h00000000),
	.mem_data_in(32'h00000000),
	.mem_data_out(),
	.mem_read(),
	.mem_write(),
	.mem_size(),
	.mem_ready(stub_mem_ready),
	.mmu_data_in(mmu_data_in_64),
	.mmu_data_out(mmu_data_out_64),
	.mmu_reg_addr(mmu_reg_addr),
	.mmu_read(mmu_reg_read),
	.mmu_write(mmu_reg_write),
	.mmu_size(mmu_reg_size),
	.atc_flush(),
	.atc_flush_all(),
	.pmove_done(pmove_done),
	.pmove_busy(pmove_busy)
);

// PFLUSH Executor (Stub)
TG68K030_PFLUSH_Execute pflush_exec
(
	.clk(clk),
	.reset(~reset),
	.pflush_start(pflush_start),
	.pflush_mode(pflush_mode),
	.pflush_fc(3'b000),
	.atc_inv_addr(32'h00000000),
	.atc_inv_req(),
	.atc_inv_ack(stub_atc_inv_ack),
	.pflush_done(pflush_done),
	.pflush_busy(pflush_busy)
);

// PTEST Executor (Stub)
TG68K030_PTEST_Execute ptest_exec
(
	.clk(clk),
	.reset(~reset),
	.ptest_start(ptest_start),
	.ptest_level(3'b000),
	.ptest_fc(3'b000),
	.ptest_rw(1'b0),
	.test_addr(32'h00000000),
	.atc_hit(),
	.atc_entry(),
	.walk_start(),
	.walk_done(1'b1),
	.walk_result(16'h0000),
	.mmusr_update(),
	.mmusr_value(),
	.return_reg(3'b000),
	.return_value(),
	.return_write(),
	.ptest_done(ptest_done),
	.ptest_busy(ptest_busy)
);

// Execution Coordinator
reg pmove_start_r, pflush_start_r, ptest_start_r;

always @(posedge clk) begin
	if (~reset) begin
		pmove_start_r <= 1'b0;
		pflush_start_r <= 1'b0;
		ptest_start_r <= 1'b0;
		fline_exec_done <= 1'b0;
	end
	else if (fline_exec_req && !fline_exec_done) begin
		// Start appropriate executor
		if (fline_is_pmove && !pmove_busy) begin
			pmove_start_r <= 1'b1;
		end
		else if (fline_is_pflush && !pflush_busy) begin
			pflush_start_r <= 1'b1;
		end
		else if (fline_is_ptest && !ptest_busy) begin
			ptest_start_r <= 1'b1;
		end

		// Signal completion when executor done
		fline_exec_done <= pmove_done | pflush_done | ptest_done;
	end
	else begin
		pmove_start_r <= 1'b0;
		pflush_start_r <= 1'b0;
		ptest_start_r <= 1'b0;
		fline_exec_done <= 1'b0;
	end
end

assign pmove_start = pmove_start_r;
assign pflush_start = pflush_start_r;
assign ptest_start = ptest_start_r;

endmodule
