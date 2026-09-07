#!/usr/bin/env python3
"""Compare the DMA arbiter against a git revision with bounded Verilator runs."""
import argparse
from pathlib import Path
import subprocess

from run_verilator import execute, HERE, ROOT, RTL


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference", default="a48b5c30")
    parser.add_argument("--work", type=Path, default=Path("/tmp/ap040-dma-equivalence"))
    args = parser.parse_args()
    work = args.work.resolve()
    work.mkdir(parents=True, exist_ok=True)
    reference = work / "reference.v"
    original = subprocess.check_output(
        ["git", "show", args.reference + ":rtl/chipdma_arb.v"], cwd=ROOT, text=True)
    reference.write_text(original.replace("module chipdma_arb", "module chipdma_reference", 1))
    execute(["verilator", "--binary", "--timing", "-j", "8", "-Wno-fatal",
             "--top-module", "tb_dma_equivalence", "--Mdir", work / "obj",
             HERE / "tb_chipdma_equivalence.v", reference, HERE / "sim_lcell.v",
             RTL / "chipdma_arb.v", RTL / "memory_router.v"], work / "compile.log", 300)
    log = work / "run.log"
    execute([work / "obj/Vtb_dma_equivalence"], log, 30)
    if "ALL TESTS PASSED" not in log.read_text():
        raise RuntimeError(f"DMA equivalence failed: {log}")
    print(log.read_text(), end="")


if __name__ == "__main__":
    main()
