// Functional model of the Intel LCELL buffer primitive. Physical delay and
// retention are checked by Quartus fitting and TimeQuest, not RTL simulation.
module lcell(input in, output out);
assign out = in;
endmodule
