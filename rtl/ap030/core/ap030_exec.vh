// AP68030 core - sequencer state bodies (included inside the clocked block)
case (state)
`include "core/ap030_exec_a.vh"
`include "core/ap030_exec_b.vh"
`include "core/ap030_exec_c.vh"
default: state <= S_FETCH;
endcase
