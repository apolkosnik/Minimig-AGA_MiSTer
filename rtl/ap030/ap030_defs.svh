//--------------------------------------------------------------------------//
// AP68030 - MC68030 compatible CPU                                         //
//                                                                          //
// ap030_defs.svh - constants shared by every module                        //
//                                                                          //
// References are to the MC68030 User's Manual (MC68030UM/AD rev 3) unless  //
// noted: "UM 7.2.1" is section 7.2.1, "PRM" is the M68000 Programmer's     //
// Reference Manual.                                                        //
//--------------------------------------------------------------------------//

`ifndef AP030_DEFS_SVH
`define AP030_DEFS_SVH

// Function codes (UM Table 4-1)
`define FC_USER_DATA   3'd1
`define FC_USER_PROG   3'd2
`define FC_SUPER_DATA  3'd5
`define FC_SUPER_PROG  3'd6
`define FC_CPU_SPACE   3'd7

// SIZ1:SIZ0 pin encoding (UM Table 7-2): bytes remaining in the operand
`define SIZ_LONG   2'b00
`define SIZ_BYTE   2'b01
`define SIZ_WORD   2'b10
`define SIZ_3BYTE  2'b11

// Port size as reported by DSACK1:DSACK0 (UM Table 7-1) or STERM
`define PORT_8    2'd0
`define PORT_16   2'd1
`define PORT_32   2'd2

// Internal operand sizes
`define SZ_B  2'd0
`define SZ_W  2'd1
`define SZ_L  2'd2
`define SZ_3  2'd3   // three bytes: the rerun of a faulted second portion (UM 8.2.1 SIZE)

// SR bits
`define SR_C   0
`define SR_V   1
`define SR_Z   2
`define SR_N   3
`define SR_X   4
`define SR_M   12
`define SR_S   13
`define SR_T0  14
`define SR_T1  15
`define SR_RESET  16'h2700
`define SR_MASK   16'hF71F
`define CCR_MASK  16'h001F

// Exception vectors (UM Table 8-1)
`define VEC_BUSERR    8'd2
`define VEC_ADDRERR   8'd3
`define VEC_ILLEGAL   8'd4
`define VEC_DIVZERO   8'd5
`define VEC_CHK       8'd6
`define VEC_TRAPCC    8'd7
`define VEC_PRIV      8'd8
`define VEC_TRACE     8'd9
`define VEC_ALINE     8'd10
`define VEC_FLINE     8'd11
`define VEC_CPPROTO   8'd13
`define VEC_FMTERR    8'd14
`define VEC_UNINIT    8'd15
`define VEC_SPURIOUS  8'd24
`define VEC_AUTOVEC   8'd24   // + level
`define VEC_TRAP      8'd32   // + n
`define VEC_MMUCONF   8'd56

// Exception stack frame formats (UM 8.4)
`define FMT_NORMAL    4'h0
`define FMT_THROWAWAY 4'h1
`define FMT_SIXWORD   4'h2
`define FMT_CPMID     4'h9
`define FMT_SHORTBUS  4'hA
`define FMT_LONGBUS   4'hB

// CACR bits (UM Figure 6-14)
`define CACR_EI   0
`define CACR_FI   1
`define CACR_CEI  2
`define CACR_CI   3
`define CACR_IBE  4
`define CACR_ED   8
`define CACR_FD   9
`define CACR_CED  10
`define CACR_CD   11
`define CACR_DBE  12
`define CACR_WA   13
`define CACR_MASK 32'h0000_3F1F   // bits that are stored (CD/CED/CI/CEI read as zero)
`define CACR_RDMASK 32'h0000_3313

// MMU status register (UM Figure 9-38)
`define MMUSR_B   15
`define MMUSR_L   14
`define MMUSR_S   13
`define MMUSR_W   11
`define MMUSR_I   10
`define MMUSR_M   9
`define MMUSR_T   6
// bits 2:0 = N

// ALU operations
`define ALU_MOVE   6'd0
`define ALU_ADD    6'd1
`define ALU_ADDX   6'd2
`define ALU_SUB    6'd3
`define ALU_SUBX   6'd4
`define ALU_CMP    6'd5
`define ALU_AND    6'd6
`define ALU_OR     6'd7
`define ALU_EOR    6'd8
`define ALU_NOT    6'd9
`define ALU_NEG    6'd10
`define ALU_NEGX   6'd11
`define ALU_CLR    6'd12
`define ALU_TST    6'd13
`define ALU_EXT    6'd14
`define ALU_EXTB   6'd15
`define ALU_SWAP   6'd16
`define ALU_TAS    6'd17
`define ALU_ABCD   6'd18
`define ALU_SBCD   6'd19
`define ALU_NBCD   6'd20
`define ALU_ASL    6'd21
`define ALU_ASR    6'd22
`define ALU_LSL    6'd23
`define ALU_LSR    6'd24
`define ALU_ROL    6'd25
`define ALU_ROR    6'd26
`define ALU_ROXL   6'd27
`define ALU_ROXR   6'd28
`define ALU_BTST   6'd29
`define ALU_BCHG   6'd30
`define ALU_BCLR   6'd31
`define ALU_BSET   6'd32
`define ALU_MOVEB  6'd33   // MOVE: flags from source, no X (same as MOVE)
`define ALU_SUBA   6'd34   // address arithmetic: no flags
`define ALU_ADDA   6'd35
`define ALU_MOVEA  6'd36
`define ALU_CMPA   6'd37   // CMPA: operands sign-extended to 32 by the core; long compare
`define ALU_PASSB  6'd38   // result = b, flags unchanged

// Bus controller transaction kinds
`define BK_DATA  2'd0   // ordinary operand / prefetch transfer
`define BK_IACK  2'd1   // interrupt acknowledge (AVEC honoured, vector on low port byte)
`define BK_TABLE 2'd2   // MMU table search (RMC asserted by the requester)

`endif // AP030_DEFS_SVH
