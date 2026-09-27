#!/usr/bin/env python3
"""Check the production HDMI output block against its original latency.

RGB, HS, VS and DE must all gain exactly one clock, including mode changes
between direct video, scaler output and composite sync. Tests both builds.
"""
import argparse
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work", type=Path, required=True)
    args = parser.parse_args()
    work = args.work.resolve()
    work.mkdir(parents=True, exist_ok=True)
    source = (ROOT / "sys/sys_top.v").read_text()
    start = source.index("reg hdmi_out_hs;")
    end = source.index("assign HDMI_TX_D  = hdmi_out_d;", start)
    block = source[start:end] + "assign HDMI_TX_D = hdmi_out_d;\n"
    inputs = ["hdmi_tx_clk", "vga_fb", "direct_video", "csync_en",
              "dv_hs", "dv_vs", "dv_de", "hdmi_cs_osd", "hdmi_hs_osd",
              "hdmi_vs_osd", "hdmi_de_osd", "dv_data", "hdmi_data_osd"]
    ports = """(
      input hdmi_tx_clk, vga_fb, direct_video, csync_en,
      input dv_hs, dv_vs, dv_de, hdmi_cs_osd, hdmi_hs_osd, hdmi_vs_osd, hdmi_de_osd,
      input [23:0] dv_data, hdmi_data_osd,
      output HDMI_TX_HS, HDMI_TX_VS, HDMI_TX_DE,
      output [23:0] HDMI_TX_D);
"""
    reference = """
      reg [26:0] dv_q, selected_q, output_q;
      always @(posedge hdmi_tx_clk) begin
        dv_q <= {dv_hs,dv_vs,dv_de,dv_data};
`ifdef MISTER_DEBUG_NOHDMI
        selected_q <= dv_q;
`else
        if (!vga_fb && direct_video) selected_q <= dv_q;
        else selected_q <= {(direct_video && csync_en) ? hdmi_cs_osd : hdmi_hs_osd,
                            hdmi_vs_osd,hdmi_de_osd,hdmi_data_osd};
`endif
        output_q <= selected_q;
      end
      assign {HDMI_TX_HS,HDMI_TX_VS,HDMI_TX_DE,HDMI_TX_D} = output_q;
"""
    text = "`timescale 1ns/1ps\nmodule candidate " + ports + block + "endmodule\n"
    text += "module reference " + ports + reference + "endmodule\n"
    text += """module tb;
      reg hdmi_tx_clk=0;
      always #5 hdmi_tx_clk=~hdmi_tx_clk;
      reg vga_fb=0,direct_video=0,csync_en=0;
      reg dv_hs=0,dv_vs=0,dv_de=0,hdmi_cs_osd=0,hdmi_hs_osd=0,hdmi_vs_osd=0,hdmi_de_osd=0;
      reg [23:0] dv_data=0,hdmi_data_osd=0;
      wire [26:0] actual,original;
      reg [26:0] delayed_original;
      always @(posedge hdmi_tx_clk) delayed_original <= original;
"""
    for module, signal in (("candidate", "actual"), ("reference", "original")):
        connections = [f".{name}({name})" for name in inputs]
        connections += [f".HDMI_TX_HS({signal}[26])", f".HDMI_TX_VS({signal}[25])",
                        f".HDMI_TX_DE({signal}[24])", f".HDMI_TX_D({signal}[23:0])"]
        text += f"{module} {module}_inst(" + ",".join(connections) + ");\n"
    text += """
      integer n;
      initial begin
        for (n=0;n<10000;n=n+1) begin
          @(negedge hdmi_tx_clk);
          {vga_fb,direct_video,csync_en}=n[2:0];
          {dv_hs,dv_vs,dv_de,hdmi_cs_osd,hdmi_hs_osd,hdmi_vs_osd,hdmi_de_osd}=$random;
          dv_data=$random;
          hdmi_data_osd=$random;
          @(posedge hdmi_tx_clk);
          #1;
          if (n>5 && actual !== delayed_original)
            $fatal(1,"RGB/sync alignment mismatch at cycle %0d",n);
        end
        $display("PASS: 10000 HDMI cycles, RGB/HS/VS/DE delayed together by one clock");
        $finish;
      end
    endmodule
"""
    bench = work / "tb_hdmi_output_pipeline.v"
    bench.write_text(text)
    for label, options in (("normal", []), ("debug", ["-DMISTER_DEBUG_NOHDMI"])):
        image = work / (label + ".vvp")
        subprocess.run(["iverilog", "-g2012", "-s", "tb", *options,
                        "-o", str(image), str(bench)], check=True, timeout=60)
        subprocess.run(["vvp", str(image)], check=True, timeout=60)


if __name__ == "__main__":
    main()
