#!/usr/bin/env python3
"""Measure RESET output duration and overlap with a delayed posted write.

This is a diagnostic, not a test of a claimed architectural RESET barrier.
The flat memory continues servicing writes during reset; it does not model
the board's reset distribution or assert that an overlapping write is lost.
NOP-before-RESET and posting-disabled runs provide ordering controls.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

from audit_execution_sequences import AP, HERE, ROOT, run


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work", type=Path, default=Path("/tmp/ap040-reset-audit"))
    parser.add_argument("--jobs", type=int, default=4)
    args = parser.parse_args()
    work = args.work.resolve()
    snap = work / "source"
    snap.mkdir(parents=True, exist_ok=True)
    inputs = [HERE / "tb_ap040_program.v", HERE / "sim_dpram.v",
              ROOT / "rtl/memory_router.v", *sorted(AP.glob("*.v")),
              *sorted(AP.glob("*.svh"))]
    for path in inputs:
        (snap / path.name).write_bytes(path.read_bytes())

    bench_path = snap / "tb_ap040_program.v"
    bench = bench_path.read_text()
    marker = "reg [2:0] lat_cnt;"
    assert bench.count(marker) == 1
    bench = bench.replace(marker, """
integer store_delay = 0;
integer store_wait = 200;
integer reset_ticks = 0;
integer reset_clocks = 0;
reg reset_seen = 0;
initial begin
 if ($value$plusargs("store_wait=%d", store_wait)) begin end
end
always @(posedge clk) begin
 if (!nreset || busstate != 2'b11 || addr_out != 32'h3000 || data_write != 1)
  store_delay <= 0;
 else if (store_delay < store_wait) store_delay <= store_delay + 1;
 if (!nreset) begin
  reset_ticks = 0;
  reset_clocks = 0;
  reset_seen = 0;
 end else if (!nresetout) begin
  if (!reset_seen)
   $display("RESET_BEGIN phase=%0d posted=%b bus=%b committed=%04x",
            phase, post_drain, busstate, mem[16'h3000 >> 1]);
  reset_seen = 1;
  reset_clocks = reset_clocks + 1;
  if (dut.core.ce) reset_ticks = reset_ticks + 1;
 end else if (reset_seen) begin
  $display("RESET_END phase=%0d ticks=%0d clocks=%0d", phase, reset_ticks, reset_clocks);
  reset_seen = 0;
  reset_ticks = 0;
  reset_clocks = 0;
 end
end
reg [2:0] lat_cnt;""")
    marker = "else if (phase == 2) begin"
    assert bench.count(marker) == 1
    bench = bench.replace(marker, """else if (busstate == 2'b11 && addr_out == 32'h3000 &&
             data_write == 1 && store_delay < store_wait) begin
  mem_ready <= 0;
end
else if (phase == 2) begin""")
    bench_path.write_text(bench)
    hashes = {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
              for p in sorted(snap.iterdir()) if p.is_file()}
    (work / "source_sha256.json").write_text(json.dumps(hashes, indent=2) + "\n")
    (work / "git-head.txt").write_text(subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True))

    images = {}
    for barrier in (False, True):
        name = "nop-reset" if barrier else "reset"
        asm, binary, image = [work / (name + suffix) for suffix in (".s", ".bin", ".hex")]
        asm.write_text(""" org 0
 dc.l $3400,start
 rept 62
 dc.l fail
 endr
 org $400
start:
 move.l #$80008000,d0
 movec d0,cacr
 lea ($3000).l,a0
 moveq #0,d0
 jsr target
 moveq #1,d0
 jsr target
 cmpi.w #1,($3000).l
 bne fail
 move.w #$600d,($f102).l
 bra.s *
fail:
 move.w #$bad0,($f102).l
 bra.s *
 cnop 0,16
target:
 move.w d0,(a0)
 tst.l d0
 beq.s done
""" + (" nop\n" if barrier else "") + " reset\ndone:\n rts\n")
        run([os.environ.get("VASM", "/opt/amiga-cc/vbcc/bin/vasmm68k_mot"),
             "-quiet", "-Fbin", "-m68040", "-no-opt", "-o", binary, asm],
            work / (name + ".assemble.log"))
        data = binary.read_bytes()
        image.write_text("".join(data[i:i+2].hex() + "\n" for i in range(0, len(data), 2)))
        images[name] = image

    results = []
    for posted in (0, 1):
        obj = work / f"obj-post{posted}"
        run(["verilator", "--binary", "--timing", "--top-module", "tb_ap040_program",
             "--Mdir", obj, "-j", args.jobs, "-Wno-fatal", "-I" + str(snap),
             f"-GPOST_STORES={posted}",
             *[snap / p.name for p in inputs if p.suffix == ".v"]],
            work / f"compile-post{posted}.log")
        for name, image in images.items():
            for delay in (0, 32, 200):
                log = work / f"post{posted}-{name}-{delay}.log"
                run([obj / "Vtb_ap040_program", "+prog=" + str(image),
                     f"+store_wait={delay}"], log)
                text = log.read_text()
                assert "ALL TESTS PASSED" in text and "FAIL:" not in text, log
                begins = re.findall(r"RESET_BEGIN phase=(\d+) posted=(\d) bus=(\d+) committed=(\w+)", text)
                ends = re.findall(r"RESET_END phase=(\d+) ticks=(\d+) clocks=(\d+)", text)
                assert len(begins) == len(ends) == 3, log
                result = dict(posted=posted, program=name, delay=delay,
                              begins=begins, ends=ends, log=str(log))
                results.append(result)
                print(json.dumps(result), flush=True)
    (work / "results.json").write_text(json.dumps(results, indent=2) + "\n")


if __name__ == "__main__":
    main()
