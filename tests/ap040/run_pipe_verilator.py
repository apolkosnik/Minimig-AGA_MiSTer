#!/usr/bin/env python3
"""Run the pipelined core's milestone benches under Verilator.

Upstream ships tb/run_pipe_tests.sh, which drives iverilog. This project
uses Verilator only. Nothing in the benches themselves needed changing:
each pokes its own program into ap040_inst_fetch.v's ROM at time 0, so
there is no assembler dependency and no 4-state X requirement.

tb_ap040_pipe_l1_wbuf tests ap040_pipe_l1.v standalone, so it gets only
that file; compiling it against the full list would put two
top-level-instantiable modules in one unit.
"""
import argparse, subprocess, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
RTL = ROOT / "rtl/ap040_pipe"
TB = HERE / "pipe"

CORE = [RTL / n for n in (
    "ap040_pipe_core.v", "ap040_inst_fetch.v", "ap040_decode.v",
    "ap040_ea_calc.v", "ap040_ea_fetch.v", "ap040_execute.v",
    "ap040_writeback.v", "ap040_pipe_alu.v", "ap040_pipe_regfile.v",
    "ap040_pipe_l1.v")]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--work", type=Path, default=Path("/tmp/ap040-pipe"))
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--only", help="comma-separated bench names")
    args = ap.parse_args()
    work = args.work.resolve(); work.mkdir(parents=True, exist_ok=True)

    benches = sorted(TB.glob("tb_ap040_pipe_*.v"))
    if args.only:
        want = set(args.only.split(","))
        benches = [b for b in benches if b.stem in want or
                   b.stem.replace("tb_ap040_pipe_", "") in want]

    passed, failed = [], []
    for b in benches:
        name = b.stem
        src = [RTL / "ap040_pipe_l1.v"] if name.endswith("l1_wbuf") else CORE
        obj = work / ("obj-" + name)
        log = work / (name + ".log")
        with log.open("w") as out:
            rc = subprocess.run(
                ["verilator", "--binary", "--timing", "--top-module", name,
                 "--Mdir", str(obj), "-j", str(args.jobs), "-Wno-fatal",
                 "-I" + str(RTL), str(b)] + [str(s) for s in src],
                stdout=out, stderr=subprocess.STDOUT).returncode
            if rc == 0:
                rc = subprocess.run([str(obj / ("V" + name))], stdout=out,
                                    stderr=subprocess.STDOUT, timeout=300).returncode
        text = log.read_text()
        ok = rc == 0 and not any(m in text for m in ("FAIL", "ERROR:", "MISMATCH", "%Error"))
        (passed if ok else failed).append(name)
        print(f"  {'ok  ' if ok else 'FAIL'} {name}", flush=True)

    print(f"\n{len(passed)}/{len(benches)} pipelined milestone benches passed under Verilator")
    if failed:
        print("failed:", ", ".join(failed))
        raise SystemExit(1)


if __name__ == "__main__":
    main()
