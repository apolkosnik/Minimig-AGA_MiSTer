// AP68020 core - sequencer state bodies (included inside the clocked block)
case (state)
`include "core/ap020_exec_a.vh"
`include "core/ap020_exec_b.vh"
`include "core/ap020_exec_m.vh"
default: begin
	if (COPROCESSOR) begin
		case (state)
`include "core/ap020_exec_c.vh"
		default: state <= S_FETCH;
		endcase
	end else begin
		// built without the coprocessor interface: as on a system where no
		// coprocessor answers, the instruction takes the Line F exception
		// where its first coprocessor access would be (UM 10.5.2.8);
		// cpRESTORE still reads its format word from memory first
		case (state)
		S_CPREST0: begin
			if (ea_pi) ea <= rf_b;
			rd(ea_pi ? rf_b : ea, `SZ_W, DW_TMP, S_CPREST1);
		end
		S_CP0, S_CP1, S_CP10, S_CP2, S_CP9, S_CPBCC,
		S_CPBCC2, S_CPCTRL, S_CPCTRL2, S_CPDBCC, S_CPDBCC2, S_CPEAX,
		S_CPMULT, S_CPMULT2, S_CPMULT3, S_CPMULT4, S_CPNULL, S_CPREG,
		S_CPREGS, S_CPREGS2, S_CPREST1, S_CPREST2, S_CPREST3, S_CPREST5,
		S_CPRS_BODY, S_CPRS_WR, S_CPSAVE0, S_CPSAVE1, S_CPSAVE2, S_CPSCC,
		S_CPSCC2, S_CPSCC_WR, S_CPSR, S_CPSR2, S_CPSR3, S_CPSV_BODY,
		S_CPSV_WR, S_CPTOS, S_CPTOS2, S_CPTRAP, S_CPTRAP2, S_CPWAIT,
		S_CPXEA, S_CPXFER, S_CPXFER2, S_CPXFER3, S_CP_ABORT, S_CP_EXC,
		S_CP_ISTREAM:
			exc_pre(`VEC_FLINE);
		default: state <= S_FETCH;
		endcase
	end
end
endcase
