#!/usr/bin/env python3
"""Build AP040 simulations with Verilator and record bounded regression runs."""
import argparse
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
RTL = ROOT / "rtl"
CORE = sorted((RTL / "ap040").glob("*.v"))
PROGRAMS = ["t_integer", "t_exceptions", "t_mmu", "t_cache", "t_fpu", "bench_loop", "bench_alu"]


def execute(command, log, timeout):
    with log.open("w") as stream:
        process = subprocess.Popen([str(x) for x in command], cwd=HERE,
                                   stdout=stream, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        try:
            code = process.wait(timeout=timeout)
        except (subprocess.TimeoutExpired, KeyboardInterrupt):
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            raise
    if code:
        raise RuntimeError(f"Command exited {code}: {log}\n{log.read_text()[-4000:]}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bench", choices=["core", "chip", "sdram", "dualram", "cache-unit", "yc-equiv", "boot-bridge"], default="core")
    parser.add_argument("--program", default="all", help="all or comma-separated assembly names")
    parser.add_argument("--work", type=Path, default=Path("/tmp/ap040-verilator"))
    parser.add_argument("--param", action="append", default=[], help="top-level PARAM=VALUE")
    parser.add_argument("--jobs", type=int, default=8)
    parser.add_argument("--timeout", type=int, default=60, help="wall seconds per simulation")
    args = parser.parse_args()
    work = args.work.resolve()
    work.mkdir(parents=True, exist_ok=True)
    programs = PROGRAMS if args.program == "all" else args.program.split(",")
    if args.bench == "chip" and args.program == "all":
        programs = [p for p in PROGRAMS if not p.startswith("bench_") and p != "t_cache"]
    elif args.bench in ("sdram", "dualram") and args.program == "all":
        # These memory-controller benches do not implement the full exception
        # suite's interrupt injection registers. Use core/chip for that suite.
        programs = ["t_integer", "t_mmu", "t_fpu"]
    tops = {"core": "tb_ap040_program", "chip": "tb_cpu_wrapper_chip",
            "sdram": "tb_sdram_turbo", "dualram": "tb_dualram_turbo",
            "cache-unit": "tb_cpu_cache_new", "yc-equiv": "tb_yc_out_equiv",
            "boot-bridge": "tb_cpu_wrapper_boot_bridge"}
    top = tops[args.bench]
    sources = [HERE / (top + ".v"), HERE / "sim_dpram.v", *CORE, RTL / "memory_router.v"]
    if args.bench == "cache-unit":
        sources = [HERE / (top + ".v"), RTL / "cpu_cache_new.v"]
        programs = ["unit"]
    elif args.bench == "boot-bridge":
        # reset-to-CIA/SERDAT startup through the production amiga_clk and
        # minimig_m68k_bridge; the "programs" are the clk_114-vs-clk_sys phase
        # and chipset-arbitration sweep the iverilog legs run (run_tests.sh)
        sources = [HERE / (top + ".v"), HERE / "sim_dpram.v", *CORE, RTL / "memory_router.v",
                   RTL / "cpu_wrapper.v", RTL / "amiga_clk.v", RTL / "minimig_m68k_bridge.v", RTL / "ciaa.v",
                   *sorted(RTL.glob("cia_*.v"))]
        programs = [f"p{ph}_d{d}" for ph in (0, 3, 7, 9) for d in (0, 1)]
    elif args.bench == "yc-equiv":
        # sys/yc_out.sv against its frozen pre-change copy, output for output
        sources = [HERE / (top + ".sv"), ROOT / "sys" / "yc_out.sv", HERE / "ref" / "yc_out_ref.sv"]
        programs = ["equiv"]
    elif args.bench != "core":
        sources += [RTL / "cpu_wrapper.v", RTL / "ram_cs_guard.v"]
    if args.bench == "chip":
        sources += [RTL / (p + ".v") for p in
                    ("fastchip", "rtg", "akiko", "akiko_hps_bridge", "akiko_nvram", "gayle", "ide")]
    elif args.bench in ("sdram", "dualram"):
        generated = work / "sdram_ctrl_sim.v"
        execute([sys.executable, HERE / "prepare_sdram_sim.py", RTL / "sdram_ctrl.v", generated],
                work / "prepare.log", 30)
        sources += [generated, RTL / "cpu_cache_new.v"]
        if args.bench == "dualram":
            sources += [RTL / "ddram_ctrl.v", RTL / "A2065/a2065_ddram_arbiter.v"]
    build = ["verilator", "--binary", "--timing", "--top-module", top,
             "--Mdir", work / "obj", "-j", str(args.jobs), "-Wno-fatal",
             "-I" + str(RTL / "ap040"), *["-G" + p for p in args.param], *sources]
    execute(build, work / "compile.log", 300)
    results = []
    for name in programs:
        command = [work / "obj" / ("V" + top)]
        if args.bench == "boot-bridge":
            ph, d = re.match(r"p(\d+)_d(\d+)", name).groups()
            command += ["+phase=" + ph, "+dbr=" + d]
        elif args.bench not in ("cache-unit", "yc-equiv"):
            image = work / (name + ".bin")
            hexf = image.with_suffix(".hex")
            execute([os.environ.get("VASM", "/opt/amiga-cc/vbcc/bin/vasmm68k_mot"),
                     "-Fbin", "-m68040", "-no-opt", "-o", image, HERE / "asm" / (name + ".s")],
                    work / (name + ".assemble.log"), 30)
            execute([sys.executable, HERE / "bin2hex.py", image, hexf], work / (name + ".hex.log"), 30)
            command += ["+prog=" + str(hexf), "+prof", "+memlat"]
        log = work / (name + ".log")
        execute(command, log, args.timeout)
        output = log.read_text()
        passed = "ALL TESTS PASSED" in output and not re.search(r"FAIL:|TEST FAILED|%Error", output)
        result = {"program": name, "passed": passed,
                  "run_cycles": [int(c) for c in re.findall(r"run passed \((\d+) cycles\)", output)],
                  "phases": [{"phase": int(p), "cycles": int(c)} for p, c in
                             re.findall(r"phase (\d+) passed \((\d+) cycles\)", output)],
                  "profile": [line for line in output.splitlines() if line.startswith(("PROF", "MEMLAT", "STAMP"))]}
        results.append(result)
        (work / "results.json").write_text(json.dumps({"bench": args.bench, "parameters": args.param,
                                                     "results": results}, indent=2) + "\n")
        print(f"{args.bench}/{name}: {'PASS' if passed else 'FAIL'} "
              f"{result['phases'] or result['run_cycles']}", flush=True)
        if not passed:
            raise RuntimeError(f"Regression failed: {log}\n{output[-4000:]}")
    print(f"All Verilator runs passed. Results: {work / 'results.json'}")


if __name__ == "__main__":
    main()
