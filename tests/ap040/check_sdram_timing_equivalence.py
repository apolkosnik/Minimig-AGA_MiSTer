#!/usr/bin/env python3
"""Compare SDRAM pins/consumer outputs against a git revision, cycle by cycle."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

from run_verilator import execute, HERE, ROOT, RTL


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference", default="f86b3980f")
    parser.add_argument("--work", type=Path, default=Path("/tmp/ap040-sdram-timing-equivalence"))
    args = parser.parse_args()
    work = args.work.resolve()
    work.mkdir(parents=True, exist_ok=True)
    old = work / "reference_original.v"
    old.write_bytes(subprocess.check_output(
        ["git", "show", args.reference + ":rtl/sdram_ctrl.v"], cwd=ROOT))
    reference = work / "reference.v"
    candidate = work / "candidate.v"
    for src, dst in [(old, reference), (RTL / "sdram_ctrl.v", candidate)]:
        execute([sys.executable, HERE / "prepare_sdram_sim.py", src, dst],
                work / (dst.stem + "_prepare.log"), 30)
    reference.write_text(reference.read_text().replace("module sdram_ctrl", "module sdram_reference", 1))
    records = []
    for cache, pipe in [(1, 0), (1, 1), (0, 0)]:
        obj = work / f"cache{cache}_pipe{pipe}"
        execute(["verilator", "--binary", "--timing", "-j", "4", "-Wno-fatal",
                 "--top-module", "tb_sdram_timing_equivalence", "--Mdir", obj,
                 f"-GCPU_CACHE={cache}", f"-GREAD_PIPE={pipe}",
                 HERE / "tb_sdram_timing_equivalence.v", reference, candidate,
                 HERE / "sim_dpram.v", RTL / "cpu_cache_new.v"],
                work / (obj.name + "_compile.log"), 300)
        for seed in [1, 271828, 314159]:
            log = work / f"{obj.name}_seed{seed}.log"
            execute([obj / "Vtb_sdram_timing_equivalence", f"+seed={seed}"], log, 60)
            result = log.read_text()
            if "ALL TESTS PASSED" not in result:
                raise RuntimeError(f"Comparison failed: {log}")
            records.append({"cache": cache, "pipe": pipe, "seed": seed, "result": result})
            print(f"cache={cache} pipe={pipe} seed={seed}: {result.splitlines()[0]}", flush=True)
    (work / "summary.json").write_text(json.dumps({
        "reference": args.reference,
        "candidate_sha256": hashlib.sha256((RTL / "sdram_ctrl.v").read_bytes()).hexdigest(),
        "results": records}, indent=2) + "\n")


if __name__ == "__main__":
    main()
