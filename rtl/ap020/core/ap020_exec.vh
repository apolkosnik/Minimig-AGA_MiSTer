// AP68020 core - sequencer state bodies (included inside the clocked block)
case (state)
`include "core/ap020_exec_a.vh"
`include "core/ap020_exec_b.vh"
`include "core/ap020_exec_c.vh"
default: state <= S_FETCH;
endcase
