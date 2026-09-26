#!/usr/bin/env python3
"""Exercise the vendored Ranzbak CPU through the production MiSTer bridges."""
import argparse
import json
import os
from pathlib import Path
import re
import sys

from run_verilator import execute

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
RTL = ROOT / "rtl"
CORE = RTL / "ap040_ranzbak"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bench", choices=["boot", "chip", "muldiv"], default="boot")
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--param", action="append", default=[])
    parser.add_argument("--program", default="t_integer,t_fastpaths,dhry")
    parser.add_argument("--require-overlap", action="store_true")
    parser.add_argument("--cpu-wrapper", type=Path, default=RTL / "cpu_wrapper.v",
                        help="optional wrapper variant for integration experiments")
    args = parser.parse_args()
    work = args.work.resolve()
    work.mkdir(parents=True, exist_ok=True)
    if args.bench == "muldiv":
        # EX with this core's multiply/divide beside upstream's
        # (tests/ap040/ranzbak_ref/): tb_ap040_rz_muldiv.v's header
        top = "tb_ap040_rz_muldiv"
        sources = [CORE / "ap040_pipe_pkg.sv", CORE / "ap040_execute.v", CORE / "ap040_pipe_muldiv.v",
                   CORE / "ap040_pipe_alu.v", HERE / "ranzbak_ref" / "ap040_execute_ref.v",
                   HERE / "ranzbak_ref" / "ap040_pipe_muldiv_ref.v", HERE / (top + ".v")]
    else:
        top = "tb_cpu_wrapper_" + ("boot_bridge" if args.bench == "boot" else "chip_bridge")
        sources = [CORE / "ap040_pipe_pkg.sv", *sorted(CORE.glob("*.v")),
                   *sorted((CORE / "compat").glob("*.v")), HERE / "sim_dpram.v",
                   HERE / (top + ".v"), args.cpu_wrapper.resolve(), RTL / "memory_router.v",
                   RTL / "amiga_clk.v", RTL / "minimig_m68k_bridge.v"]
    if args.bench == "boot":
        sources += [RTL / "ciaa.v", *sorted(RTL.glob("cia_*.v"))]
    params = (["FAST_CLOCK=0"] if args.bench == "boot" else []) + args.param
    execute(["verilator", "--binary", "--timing", "--top-module", top,
             "--Mdir", work / "obj", "-j", "4", "-Wno-fatal",
             "-I" + str(CORE), "-I" + str(CORE / "compat"),
             *["-G" + p for p in params], *sources], work / "compile.log", 600)
    cases = ([f"p{p}_d{d}" for p in (0, 3, 7, 9) for d in (0, 1)] if args.bench == "boot" else
             ["ce_on", "ce_random"] if args.bench == "muldiv" else args.program.split(","))
    results = []
    for name in cases:
        command = [work / "obj" / ("V" + top)]
        if args.bench == "boot":
            phase, dbr = re.fullmatch(r"p(\d+)_d(\d+)", name).groups()
            command += ["+phase=" + phase, "+dbr=" + dbr]
        elif args.bench == "muldiv":
            if name == "ce_random":
                command += ["+ce_random"]
        else:
            vasm = os.environ.get("VASM", "/opt/amiga-cc/vbcc/bin/vasmm68k_mot")
            image = work / (name + ".bin")
            hexf = image.with_suffix(".hex")
            cfile = HERE / "c" / (name + ".c")
            if cfile.exists():
                execute([vasm, "-quiet", "-Fhunk", "-m68040", "-o", work / "start.o",
                         HERE / "c/start.s"], work / (name + "-asm.log"), 30)
                env = dict(os.environ, VBCC=os.environ.get("VBCC", "/opt/amiga-cc/vbcc"),
                           PATH="/opt/amiga-cc/vbcc/bin:" + os.environ.get("PATH", ""))
                execute(["/opt/amiga-cc/vbcc/bin/vc", "+aos68k", "-c", "-O2", "-speed",
                         "-cpu=68040", "-fpu=68040", "-c99", "-o", work / (name + ".o"), cfile],
                        work / (name + "-cc.log"), 60, env)
                execute(["/opt/amiga-cc/vbcc/bin/vlink", "-brawbin1", "-o", image,
                         work / "start.o", work / (name + ".o")], work / (name + "-link.log"), 30)
            else:
                execute([vasm, "-Fbin", "-m68040", "-no-opt", "-o", image,
                         HERE / "asm" / (name + ".s")], work / (name + "-asm.log"), 30)
            execute([sys.executable, HERE / "bin2hex.py", image, hexf], work / (name + "-hex.log"), 30)
            command += ["+prog=" + str(hexf)]
            if args.require_overlap:
                command += ["+require_overlap"]
        log = work / (name + ".log")
        execute(command, log, 1800 if args.bench == "muldiv" else 180)
        output = log.read_text()
        passed = "ALL TESTS PASSED" in output and not re.search(r"FAIL|%Error", output)
        results.append({"case": name, "passed": passed,
                        "cycles": re.findall(r"run passed \((\d+) cycles\)", output),
                        "overlap": re.findall(r"overlap cycles: (\d+)", output)})
        (work / "results.json").write_text(json.dumps({"bench": args.bench,
            "parameters": params, "results": results}, indent=2) + "\n")
        print(name, "PASS" if passed else "FAIL", flush=True)
        if not passed:
            raise RuntimeError(output)


if __name__ == "__main__":
    main()
