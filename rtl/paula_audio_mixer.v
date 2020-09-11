// stereo volume control
// channel 1&2 --> left
// channel 0&3 --> right
// fixed by OKK 2012-9-07


module paula_audio_mixer (
  input   clk,        //bus clock
  input clk7_en,
  input cck,
  input  [7:0] sample0,    //sample 0 input
  input  [7:0] sample1,    //sample 1 input
  input  [7:0] sample2,    //sample 2 input
  input  [7:0] sample3,    //sample 3 input
  output reg  [8:0]ldatasum,    //left DAC data
  output reg  [8:0]rdatasum    //right DAC data
);

// channel mixing
// !!! this is NOT 28MHz clock !!! (It is cck 3.5MHz)
always @ (posedge clk) begin
  if (clk7_en && cck) begin
    ldatasum <= #1 {sample1[7], sample1[7:0]} + {sample2[7], sample2[7:0]};
    rdatasum <= #1 {sample0[7], sample0[7:0]} + {sample3[7], sample3[7:0]};
  end
end


endmodule

