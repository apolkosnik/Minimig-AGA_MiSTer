module altsource_probe
#(
    parameter sld_auto_instance_index = "YES",
    parameter sld_instance_index = 0,
    parameter instance_id = "STUB",
    parameter probe_width = 1,
    parameter source_width = 1,
    parameter enable_metastability = "NO"
)
(
    input  [probe_width-1:0] probe,
    output [source_width-1:0] source
);

generate
if (source_width > 0) begin : gen_source
    assign source = {source_width{1'b0}};
end
endgenerate

endmodule
