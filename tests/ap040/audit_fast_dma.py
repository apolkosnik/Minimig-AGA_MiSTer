#!/usr/bin/env python3
"""Reproduce unsnooped Fast RAM DMA using actual cache/controller modules.

Default exits nonzero on stale CPU data. --expect-defect checks the current
failure matrix plus bypass/correct-snoop controls; it is not a release gate.
The bench models the reviewed top-level wiring. Rewire it to the production
snoop producer/merger before using it to validate a future integration fix.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]


def run(command, log):
    with log.open("w") as stream:
        subprocess.run([str(x) for x in command], cwd=ROOT, stdout=stream,
                       stderr=subprocess.STDOUT, check=True, timeout=300)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work", type=Path, default=Path("/tmp/ap040-fast-dma-audit"))
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--expect-defect", action="store_true")
    args = parser.parse_args()
    work = args.work.resolve()
    snap = work / "source"
    snap.mkdir(parents=True, exist_ok=True)
    paths = [HERE / "tb_ap040_fast_dma_audit.v", HERE / "sim_dpram.v", HERE / "sim_lcell.v",
             *[ROOT / "rtl" / name for name in (
                 "ap040/ap040_cache.v", "ap040/ap040_bus16_adapter.v", "memory_router.v",
                 "ddram_ctrl.v", "cpu_cache_new.v", "chipdma_arb.v",
                 "A2065/a2065_ddram_arbiter.v", "ap040/ap040_defs.svh")]]
    hashes = {}
    for path in paths:
        data = path.read_bytes()
        (snap / path.name).write_bytes(data)
        hashes[str(path.relative_to(ROOT))] = hashlib.sha256(data).hexdigest()
    for relative in ("Minimig.sv", "rtl/cpu_wrapper.v"):
        data = (ROOT / relative).read_bytes()
        (snap / Path(relative).name).write_bytes(data)
        hashes[relative] = hashlib.sha256(data).hexdigest()
    # The export this audit asked for now exists, so the bench drives the cache
    # from it rather than modelling its absence. Assert it is still there: if
    # the port goes away the "wired" case would quietly fall back to no
    # invalidate at all and look like a pass for the wrong reason.
    header = (snap / "ddram_ctrl.v").read_text().split(");", 1)[0]
    assert "snoop_tgl" in header, "ddram_ctrl no longer exports a snoop"
    top = (snap / "Minimig.sv").read_text()
    cpu = re.search(r"\bcpu_wrapper\s+cpu_wrapper\s*\((.*?)\n\);", top, re.S)
    assert cpu, "CPU instantiation changed: review the snoop wiring"
    ports = re.sub(r"\s+", "", cpu.group(1))
    assert ".snoop_tgl(chip_snoop_tgl)" in ports and ".snoop_adr(chip_snoop_adr)" in ports
    # The DDR side must reach the CPU too, or Fast RAM is cached unsnooped.
    assert ".ddr_snoop_tgl(ddr_snoop_tgl)" in ports and ".ddr_snoop_adr(ddr_snoop_adr)" in ports, \
        "cpu_wrapper no longer takes the DDR controller's snoop"
    assert re.search(r"output\s+snoop_tgl", (ROOT / "rtl/ddram_ctrl.v").read_text()), \
        "ddram_ctrl no longer exports a snoop"
    compat = ROOT / "rtl/ap040/ap040_tg68k_compat.v"
    text = compat.read_text()
    predicate = re.search(r"\twire cache_chip =.*?\n\twire cache_allow =", text, re.S)
    assert predicate, "cache-window extraction no longer matches"
    (snap / "audit_cache_window.svh").write_text(predicate.group(0).rsplit("\n",1)[0] + "\n")
    hashes[str(compat.relative_to(ROOT))] = hashlib.sha256(compat.read_bytes()).hexdigest()
    (snap / compat.name).write_text(text)
    (work / "source_sha256.json").write_text(json.dumps(hashes, indent=2) + "\n")
    (work / "git-head.txt").write_text(subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True))
    obj = work / "obj"
    run(["verilator", "--binary", "--timing", "--top-module", "tb_ap040_fast_dma_audit",
         "--Mdir", obj, "-j", args.jobs, "-Wno-fatal", "-I" + str(snap),
         *[snap / p.name for p in paths if p.suffix == ".v"]], work / "compile.log")
    results = []
    # "wired" now drives the cache from ddram_ctrl's REAL snoop export through
    # the same edge detection cpu_wrapper does. "unsnooped" is the pre-fix
    # world -- no invalidate reaches the CPU at all -- and must still go stale,
    # or this gate has stopped being able to see the defect it exists for.
    for mode, options in (("wired", ["+snoop=3"]), ("unsnooped", []),
                          ("bypass", ["+no_inner=1"]),
                          ("snoop", ["+snoop=1"]), ("wrong_set", ["+snoop=2"])):
        for window in range(4):
            for ce in (1, 4):
                for waits in (0, 1):
                    tag = f"{mode}-window{window}-ce{ce}-waits{waits}"
                    log = work / (tag + ".log")
                    run([obj / "Vtb_ap040_fast_dma_audit", f"+window={window}",
                         f"+ce_div={ce}", f"+waits={waits}", *options], log)
                    text = log.read_text()
                    stale = "FAIL: stale AP040 data after completed CD DMA" in text
                    passed = "ALL TESTS PASSED" in text and "FAIL:" not in text
                    assert stale != passed and "HARNESS:" not in text, log
                    observation = next(line for line in text.splitlines() if line.startswith("RESULT "))
                    row = dict(case=tag, mode=mode, passed=passed, stale=stale,
                               observation=observation, log=str(log))
                    results.append(row)
                    print(f"{'PASS' if passed else 'STALE'} {tag}: {observation}", flush=True)
    (work / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    controls_ok = all(r["passed"] for r in results if r["mode"] in ("bypass", "snoop"))
    wrong_set_ok = all(r["stale"] for r in results if r["mode"] == "wrong_set")
    unsnooped_ok = all(r["stale"] for r in results if r["mode"] == "unsnooped")
    actual_ok = all(r["stale"] if args.expect_defect else r["passed"]
                    for r in results if r["mode"] == "wired")
    if not (controls_ok and wrong_set_ok and unsnooped_ok and actual_ok):
        raise SystemExit("Fast RAM DMA audit failed: see results.json")
    print("Expected defect matrix verified" if args.expect_defect else "Fast RAM DMA checks passed")


if __name__ == "__main__":
    main()
