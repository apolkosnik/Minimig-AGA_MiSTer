#!/usr/bin/env python3
"""The AP040 regression.  Verilator is the expected simulator: run this, and
and the only one: nothing in this project runs a second simulator.

Coverage here is every leg of run_tests.sh except the snoop bench's X-poison
family -- cache_snoop_x / cache_snoop_ce4 and their +inj_* controls, which
need four-state simulation; see tb_ap040_cache_snoop.v.  Program benches go
through run_verilator.py with the same parameter presets run_tests.sh
compiles; self-checking unit benches are built here and run with their
plusargs, negative controls inverted.

The tag-row don't-care family now runs here too: sim_dpram answers a
DONT_CARE read-during-write with a deterministic pseudo-random word rather
than X, which is the honest two-state reading of "not specified" and proves
the cache tolerates any such word.  What does NOT survive the move is the two
negative controls -- see the comment on cache_snoop_x below.  Until those are
rebuilt as a direct check on the guard, that property is untested.

    python3 run_verilator_suite.py [--work DIR] [--jobs N] [--only NAME,...]
"""
import argparse, os, re, subprocess, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
RTL = ROOT / "rtl"
AP = RTL / "ap040"
CORE = sorted(AP.glob("*.v"))
SRC = CORE + [RTL / "memory_router.v"]

# --- program benches: (label, run_verilator.py arguments) ------------------
PROGRAM_RUNS = [
    ("core",            ["--bench", "core"]),
    ("chip",            ["--bench", "chip", "--program", "t_fpu,t_exceptions,t_mmu"]),
    ("chip_l0",         ["--bench", "chip", "--program", "t_exceptions", "--param", "RAM_LAT=0"]),
    ("chip_l7",         ["--bench", "chip", "--program", "t_exceptions", "--param", "RAM_LAT=7"]),
    ("chip_turbo",      ["--bench", "chip", "--program", "t_exceptions,t_mmu,t_fpu,t_integer", "--param", "TURBO_CHIP=1"]),
    ("chip_fast4",      ["--bench", "chip", "--program", "t_integer,t_exceptions,t_mmu,t_fpu,t_moves_fc", "--param", "FAST_CLOCK=1", "--param", "CORE_DIV=4"]),
    ("chip_fast2",      ["--bench", "chip", "--program", "t_integer,t_moves_fc", "--param", "FAST_CLOCK=1", "--param", "CORE_DIV=2"]),
    ("sdram",           ["--bench", "sdram", "--program", "t_fpu,t_mmu", "--param", "CYC_PHASE=1", "--param", "CPU_PHASE=0"]),
    ("sdram_ph3",       ["--bench", "sdram", "--program", "t_mmu,t_fpu", "--param", "CYC_PHASE=1", "--param", "CPU_PHASE=3"]),
    ("sdram_nx",        ["--bench", "sdram", "--program", "t_mmu,t_fpu", "--param", "CYC_PHASE=1", "--param", "CPU_PHASE=3", "--param", "CPU_CACHE=0", "--param", "MAX_CYCLES=6000000"]),
    ("dualram",         ["--bench", "dualram", "--program", "t_fpu,t_mmu", "--param", "CYC_PHASE=1", "--param", "CPU_PHASE=3"]),
    # Minimig.sv builds its controllers with CACHE_READ_PIPE(1) under the
    # legacy clocking, so the registered hit decision is what ships and these
    # two legs are the shipping configuration.  The benches default READ_PIPE
    # to FAST_CLOCK, which is 0 here, so it has to be asked for.
    ("sdram_rp1",       ["--bench", "sdram", "--program", "t_mmu,t_fpu", "--param", "CYC_PHASE=1", "--param", "CPU_PHASE=3", "--param", "READ_PIPE=1"]),
    ("dualram_rp1",     ["--bench", "dualram", "--program", "t_fpu,t_mmu", "--param", "CYC_PHASE=1", "--param", "CPU_PHASE=3", "--param", "READ_PIPE=1"]),
    ("dualram_nx",      ["--bench", "dualram", "--program", "t_fpu", "--param", "CYC_PHASE=1", "--param", "CPU_PHASE=3", "--param", "CPU_CACHE=0", "--param", "MAX_CYCLES=6000000"]),
    ("cache_unit",      ["--bench", "cache-unit"]),
    ("cache_unit_rp0",  ["--bench", "cache-unit", "--param", "READ_PIPE=0"]),
    ("yc_equiv",        ["--bench", "yc-equiv"]),
    ("boot_legacy",     ["--bench", "boot-bridge", "--param", "FAST_CLOCK=0", "--param", "CORE_DIV=4"]),
    ("boot_fast1",      ["--bench", "boot-bridge", "--param", "FAST_CLOCK=1", "--param", "CORE_DIV=1"]),
    ("boot_fast2",      ["--bench", "boot-bridge", "--param", "FAST_CLOCK=1", "--param", "CORE_DIV=2"]),
    ("boot_fast4",      ["--bench", "boot-bridge", "--param", "FAST_CLOCK=1", "--param", "CORE_DIV=4"]),
]

# --- self-checking unit benches: label -> (top, sources, [(leg, plusargs, must_fail)])
def U(top, sources, legs): return {"top": top, "sources": sources, "legs": legs}
UNIT_RUNS = {
    "reset":              U("tb_ap040_reset", [HERE / "tb_ap040_reset.v", HERE / "sim_dpram.v", *SRC], [("reset", [], False)]),
    "double_fault":       U("tb_ap040_double_fault", [HERE / "tb_ap040_double_fault.v", HERE / "sim_dpram.v", *SRC], [("double_fault", [], False)]),
    "walker_cdc":         U("tb_ap040_walker_cdc", [HERE / "tb_ap040_walker_cdc.v", AP / "ap040_walker_cdc.v"], [("walker_cdc", [], False)]),
    "bus16_gap":          U("tb_ap040_bus16_gap", [HERE / "tb_ap040_bus16_gap.v", AP / "ap040_bus16_adapter.v"], [("bus16_gap", [], False)]),
    "ddram_walker_snoop": U("tb_ddram_walker_snoop", [HERE / "tb_ddram_walker_snoop.v", RTL / "ddram_ctrl.v", RTL / "cpu_cache_new.v", RTL / "A2065" / "a2065_ddram_arbiter.v", HERE / "sim_dpram.v"], [("ddram_walker_snoop", [], False)]),
    "ddram_walker_read":  U("tb_ddram_walker_read", [HERE / "tb_ddram_walker_read.v", RTL / "ddram_ctrl.v", RTL / "cpu_cache_new.v", RTL / "A2065" / "a2065_ddram_arbiter.v", AP / "ap040_walker_cdc.v", *SRC, HERE / "sim_dpram.v"], [("ddram_walker_read", [], False)]),
    "bus_timeout":        U("tb_ap040_bus_timeout", [HERE / "tb_ap040_bus_timeout.v", AP / "ap040_bus_timeout.v"], [("bus_timeout", [], False)]),
    "cart_hrtmon":        U("tb_cart_hrtmon", [HERE / "tb_cart_hrtmon.v", RTL / "cart.v"], [("cart_hrtmon", [], False)]),
    "sdram32":            U("tb_sdram32", [HERE / "tb_sdram32.v", RTL / "sdram32_ctrl.v", "SDRAM_SIM", RTL / "cpu_cache_new.v", HERE / "sim_dpram.v"],
                           [("sdram32", [], False), ("sdram32_nomod", ["+no_module"], False),
                            ("sdram32_brk_lock", ["+break_lockstep"], True), ("sdram32_brk_lane", ["+break_laneswap"], True), ("sdram32_brk_wr", ["+break_chipwr"], True),
                            ("sdram32_brk_rowshare", ["+break_rowshare"], True),
                            ("sdram32_brk_slotphase", ["+break_slotphase"], True)]),
    "sdram32_rp1":        U("tb_sdram32", [HERE / "tb_sdram32.v", RTL / "sdram32_ctrl.v", "SDRAM_SIM", RTL / "cpu_cache_new.v", HERE / "sim_dpram.v"], [("sdram32_rp1", [], False)]),
    "cache_snoop":        U("tb_ap040_cache_snoop", [HERE / "tb_ap040_cache_snoop.v", HERE / "sim_dpram.v", AP / "ap040_cache.v"], [("cache_snoop", [], False)]),
    # CE_DIV 4 is how P2 runs the cache on silicon.
    "cache_snoop_ce4":    U("tb_ap040_cache_snoop", [HERE / "tb_ap040_cache_snoop.v", HERE / "sim_dpram.v", AP / "ap040_cache.v"], [("cache_snoop_ce4", [], False)]),
    # SNOOP_MIXED_X gives the tag row silicon's mixed-port read-during-write, so
    # the collision the lookup guard exists for is observable.  Each guard term
    # is load-bearing in one divide and redundant in the other, which is why the
    # controls are one per divide: see the matrix in tb_ap040_cache_snoop.v.
    # The don't-care family.  The bench builds a DIRECTED row -- the tag the
    # lookup wants, valid, in a way that does not hold the line -- so acting on
    # a collided row hits the wrong way and returns its word, which expect_read
    # catches.  That restores cache_snoop_x_ce4_neg_lkw, the divide-4 control.
    #
    # Both controls are restored, and both now fail on concrete wrong data
    # rather than on X propagation.  The divide-1 one needed T13: T3 already
    # sweeps a snoop across the acceptance window, but its concurrent read is
    # deliberately unchecked (either value is legal against an unordered
    # snoop), so the one read that could show the collision was the one the
    # bench ignored.  T13 checks it -- either value is legal, a THIRD is not.
    "cache_snoop_x":      U("tb_ap040_cache_snoop", [HERE / "tb_ap040_cache_snoop.v", HERE / "sim_dpram.v", AP / "ap040_cache.v"],
                            [("cache_snoop_x", [], False),
                             ("cache_snoop_x_lkw", ["+inj_look_whole"], False),
                             ("cache_snoop_x_neg_accw", ["+inj_acc_whole"], True)]),
    "cache_snoop_x_ce4":  U("tb_ap040_cache_snoop", [HERE / "tb_ap040_cache_snoop.v", HERE / "sim_dpram.v", AP / "ap040_cache.v"],
                            [("cache_snoop_x_ce4", [], False),
                             ("cache_snoop_x_ce4_accw", ["+inj_acc_whole"], False),
                             ("cache_snoop_x_ce4_accs", ["+inj_acc_settle"], False),
                             ("cache_snoop_x_ce4_neg_lkw", ["+inj_look_whole"], True)]),
}
UNIT_PARAMS = {"sdram32_rp1": ["-GREAD_PIPE=1"], "cache_snoop_ce4": ["-GCE_DIV=4"],
               "cache_snoop_x": ["+define+SNOOP_MIXED_X"],
               "cache_snoop_x_ce4": ["+define+SNOOP_MIXED_X", "-GCE_DIV=4"]}


def run(cmd, log, cwd=HERE, timeout=900):
    with open(log, "w") as f:
        p = subprocess.run([str(c) for c in cmd], cwd=cwd, stdout=f, stderr=subprocess.STDOUT, timeout=timeout)
    return p.returncode


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--work", type=Path, default=Path("/tmp/ap040-verilator-suite"))
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--only", default="", help="comma-separated labels to run")
    a = ap.parse_args()
    a.work.mkdir(parents=True, exist_ok=True)
    only = set(x for x in a.only.split(",") if x)
    results = []
    # the sdram controller's simulation copy (declaration hoisting + tristate split), as run_tests.sh makes it
    sdram_sim = a.work / "sdram_ctrl_sim.v"
    run([sys.executable, HERE / "prepare_sdram_sim.py", RTL / "sdram_ctrl.v", sdram_sim], a.work / "prepare.log", timeout=60)
    for label, args in PROGRAM_RUNS:
        if only and label not in only: continue
        log = a.work / f"{label}.log"
        rc = run([sys.executable, HERE / "run_verilator.py", *args, "--work", a.work / label, "--jobs", str(a.jobs)], log)
        text = log.read_text()
        n_pass = len(re.findall(r": PASS", text)); n_fail = len(re.findall(r": FAIL", text))
        ok = rc == 0 and n_fail == 0 and n_pass > 0
        results.append((label, ok, f"{n_pass} pass, {n_fail} fail"))
        print(f"{'ok  ' if ok else 'FAIL'} {label:20s} {n_pass} pass, {n_fail} fail", flush=True)
    for label, u in UNIT_RUNS.items():
        if only and label not in only: continue
        work = a.work / label; work.mkdir(exist_ok=True)
        sources = [sdram_sim if s == "SDRAM_SIM" else s for s in u["sources"]]
        build = ["verilator", "--binary", "--timing", "--top-module", u["top"], "--Mdir", work / "obj", "-j", str(a.jobs),
                 "-Wno-fatal", "-I" + str(AP), *UNIT_PARAMS.get(label, []), *sources]
        if run(build, work / "compile.log") != 0:
            results.append((label, False, "compile failed")); print(f"FAIL {label:20s} compile failed (see {work/'compile.log'})", flush=True); continue
        for leg, plus, must_fail in u["legs"]:
            log = work / f"{leg}.log"
            rc = run([work / "obj" / ("V" + u["top"]), *plus], log, timeout=1200)
            text = log.read_text()
            passed = "ALL TESTS PASSED" in text and not re.search(r"FAIL:|TEST FAILED|%Error|%Fatal", text)
            failed = bool(re.search(r"TEST FAILED|%Fatal|FAIL:", text))
            ok = failed if must_fail else passed
            results.append((leg, ok, "must fail" if must_fail else "")); print(f"{'ok  ' if ok else 'FAIL'} {leg:20s} {'(control: must fail)' if must_fail else ''}", flush=True)
    bad = [r for r in results if not r[1]]
    print(f"\n{len(results) - len(bad)}/{len(results)} legs passed under Verilator" + ("" if not bad else "; FAILED: " + ", ".join(r[0] for r in bad)))
    print("Both snoop guard terms are covered by must-fail controls again, on concrete wrong data rather than X.")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
