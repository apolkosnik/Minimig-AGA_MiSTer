#!/usr/bin/env python3
"""Run the pipelined core's milestone benches under Verilator.

Upstream ships tb/run_pipe_tests.sh, which drives iverilog. This project
uses Verilator only. Nothing in the benches themselves needed changing:
each pokes its own program into ap040_inst_fetch.v's ROM at time 0, so
there is no assembler dependency and no 4-state X requirement.

tb_ap040_pipe_l1_wbuf tests ap040_pipe_l1.v standalone, so it gets only
that file; compiling it against the full list would put two
top-level-instantiable modules in one unit. tb_ap040_pipe_alu_equiv
compares ap040_pipe_alu.v against the FSM core's rtl/ap040/ap040_alu.v,
so it gets those two files and both include directories.
"""
import argparse, os, shutil, subprocess, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
RTL = ROOT / "rtl/ap040_pipe"
TB = HERE / "pipe"

CORE = [RTL / n for n in (
    "ap040_pipe_core.v", "ap040_pipe_cpu.v", "ap040_pipe_sys.v",
    "ap040_pipe_membus.v", "ap040_inst_fetch.v", "ap040_decode.v",
    "ap040_ea_calc.v", "ap040_ea_fetch.v", "ap040_execute.v",
    "ap040_writeback.v", "ap040_pipe_alu.v", "ap040_pipe_regfile.v",
    "ap040_pipe_l1.v")]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--work", type=Path, default=Path("/tmp/ap040-pipe"))
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--only", help="comma-separated bench names")
    ap.add_argument("--keep-obj", action="store_true",
                    help="keep every bench's Verilator build directory. The default deletes "
                         "one as soon as its bench PASSES: a full suite leaves about 10 GB of "
                         "precompiled headers and object files behind otherwise, ninety "
                         "milestones of that filled a 921 GB disk, and a full disk fails the "
                         "g++ step with no diagnostic at all -- which reads as a suite-wide "
                         "RTL regression. A FAILING bench keeps its directory either way, "
                         "since that is when the build and the binary are worth having.")
    ap.add_argument("--ce-random", action="store_true",
                    help="drive every bench's clock enable from a pseudo-random sequence "
                         "instead of tying it high. ce is how the real system runs this core "
                         "slower than its clock, so a cycle with it low is a cycle that did "
                         "not happen -- and eight of the thirteen defects three rounds of "
                         "external review found lived behind every bench tying it high.")
    ap.add_argument("--slow-l1", action="store_true",
                    help="build with AP040_PIPE_L1_SLOW: 0-3 extra cycles on every L1 read and "
                         "write-buffer drain, so the benches prove the pipeline waits for memory")
    args = ap.parse_args()
    work = args.work.resolve(); work.mkdir(parents=True, exist_ok=True)
    # g++ writes its temporaries to TMPDIR, which on this machine is a 31 GB
    # tmpfs shared with everything else. A full one makes the compiler exit
    # with no diagnostic, which this harness reports as a failed bench -- the
    # same false regression a full /home produced at milestone 90, from a
    # different disk. The work directory is on real storage and is where the
    # build already lives, so it holds the temporaries too.
    env = dict(os.environ, TMPDIR=str(work))

    benches = sorted(TB.glob("tb_ap040_pipe_*.v"))
    if args.only:
        want = set(args.only.split(","))
        benches = [b for b in benches if b.stem in want or
                   b.stem.replace("tb_ap040_pipe_", "") in want]

    passed, failed = [], []
    for b in benches:
        name = b.stem
        src, inc = CORE, [RTL]
        if name.endswith("l1_wbuf"):
            src = [RTL / "ap040_pipe_l1.v"]
        elif name.endswith("rmwsup"):
            # ap040_pipe_cpu.v with the memory written in the bench, so the
            # write port can be held busy -- see the bench's header.
            src = [x for x in CORE if x.name not in
                   ("ap040_pipe_core.v", "ap040_pipe_sys.v",
                    "ap040_pipe_membus.v", "ap040_pipe_l1.v")]
        elif name.endswith("busredirect"):
            # ap040_pipe_membus.v standalone, same reason as l1_wbuf above:
            # the bench drives the wrapper's ports directly.
            src = [RTL / "ap040_pipe_membus.v"]
        elif name.endswith("dual"):
            # The differential bench instantiates the FSM core beside the
            # pipelined one, so rtl/ap040's whole core comes too.
            src = CORE + [RTL / "ap040_pipe_bus16.v"] + [
                ROOT / "rtl/ap040" / n for n in (
                    "ap040_tg68k_compat.v", "ap040_core.v", "ap040_bus16_adapter.v",
                    "ap040_regfile.v", "ap040_alu.v", "ap040_muldiv.v",
                    "ap040_mmu.v", "ap040_cache.v", "ap040_fpu.v")
            ] + [HERE / "sim_dpram.v"]
            inc = [RTL, ROOT / "rtl/ap040"]
        elif name.endswith("inject"):
            # ap040_pipe_bus16.v, which brings the FSM core's adapter with it
            # -- the same top the corpus replay would drive.
            src = CORE + [RTL / "ap040_pipe_bus16.v",
                          ROOT / "rtl/ap040/ap040_bus16_adapter.v"]
            inc = [RTL, ROOT / "rtl/ap040"]
        elif name.endswith("bus16"):
            # ap040_pipe_bus16.v instantiates the FSM core's own 16-bit
            # adapter, so that file and its include directory come too.
            src = CORE + [RTL / "ap040_pipe_bus16.v",
                          ROOT / "rtl/ap040/ap040_bus16_adapter.v"]
            inc = [RTL, ROOT / "rtl/ap040"]
        elif name.endswith("alu_equiv"):
            src = [RTL / "ap040_pipe_alu.v", ROOT / "rtl/ap040/ap040_alu.v"]
            inc = [RTL, ROOT / "rtl/ap040"]
        obj = work / ("obj-" + name)
        log = work / (name + ".log")
        with log.open("w") as out:
            rc = subprocess.run(
                ["verilator", "--binary", "--timing", "--top-module", name,
                 "--Mdir", str(obj), "-j", str(args.jobs), "-Wno-fatal",
                 *("-I" + str(d) for d in inc),
                 # Every bench's end-of-program wait is `repeat (N * AP040_PIPE_WAIT_SCALE)`:
                 # the slow L1 roughly triples the cycles a program takes, so the
                 # wait scales with it rather than each bench guessing.
                 # Each mode roughly doubles or triples how long a program
                 # takes, so the end-of-program wait scales with them rather
                 # than every bench guessing.
                 "-DAP040_PIPE_WAIT_SCALE=" + ("8" if (args.slow_l1 and args.ce_random)
                                               else "4" if (args.slow_l1 or args.ce_random)
                                               else "1"),
                 *(["-DAP040_PIPE_L1_SLOW"] if args.slow_l1 else []),
                 *(["-DAP040_PIPE_CE_RANDOM"] if args.ce_random else []), str(b)] + [str(s) for s in src],
                stdout=out, stderr=subprocess.STDOUT, env=env).returncode
            if rc == 0:
                rc = subprocess.run([str(obj / ("V" + name))], stdout=out,
                                    stderr=subprocess.STDOUT, timeout=300, env=env).returncode
        text = log.read_text()
        ok = rc == 0 and not any(m in text for m in ("FAIL", "ERROR:", "MISMATCH", "%Error"))
        if ok and not args.keep_obj:
            shutil.rmtree(obj, ignore_errors=True)
        (passed if ok else failed).append(name)
        print(f"  {'ok  ' if ok else 'FAIL'} {name}", flush=True)

    print(f"\n{len(passed)}/{len(benches)} pipelined milestone benches passed under Verilator")
    if failed:
        print("failed:", ", ".join(failed))
        raise SystemExit(1)


if __name__ == "__main__":
    main()
