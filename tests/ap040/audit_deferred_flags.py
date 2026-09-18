#!/usr/bin/env python3
"""Probe deferred CCR commit at split writes and access-error entry.

Snapshots production sources before compiling. Uses the existing system bench
with result logging only; faults come from real MMU page protection. Optional
diagnostic controls modify copies of the core under --work, never production.
Ordinary runs fail on any CPU failure. --expect-defects instead asserts the
specific observed audit matrix, including passing negative controls.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
AP = ROOT / "rtl/ap040"


def run(command, log):
    with log.open("w") as stream:
        subprocess.run([str(x) for x in command], cwd=ROOT, stdout=stream,
                       stderr=subprocess.STDOUT, check=True, timeout=300)


def program(case, mode, cached):
    fault = case.startswith("entry_")
    address = "$8000" if fault else "$7ffe" if mode == "aligned" else "$7fff"
    shift = case in ("shift", "entry_roxl")
    size = "l" if case == "entry_negx" else "w"
    initial = "$8000" if shift else "1" if fault else "$ffff"
    instruction = "roxl.w" if shift else "negx.l" if fault else "addq.w #1,"
    instruction = instruction + ("" if instruction.endswith(",") else " ") + f"({address}).l"
    expected = "$ffffffff" if case == "entry_negx" else "0"
    expected_ccr = "$19" if case == "entry_negx" else "$15"
    leak = "move.w #0,ccr\n st ($3502).l\n move.w ccr,d6" if case == "leak" else ""
    checks = ("cmpi.w #0,($3510).l\n bne fail\n cmpi.w #$2700,($3512).l\n bne fail"
              if fault else "cmpi.w #0,d6\n bne fail" if case == "leak"
              else f"cmpi.w #{expected_ccr},d7\n bne fail")
    return f""" org 0
 dc.l $3400,start,handler
 org $400
start:
 clr.w ($3500).l
 clr.w ($3510).l
 clr.w ($3512).l
 lea ($4400).l,a0
 moveq #0,d0
 moveq #15,d1
tables:
 move.l d0,d2
 lsl.l #8,d2
 lsl.l #4,d2
 addq.l #3,d2
 move.l d2,(a0)+
 addq.l #1,d0
 dbra d1,tables
 move.l #$4203,($4000).l
 move.l #$4403,($4200).l
 move.{size} #{initial},({address}).l
 move.l #${'8007' if fault else '8003'},($4420).l
 move.l #$4000,d0
 movec d0,srp
 movec d0,urp
 move.l #${'0' if mode == 'tc0' else '8000'},d0
 movec d0,tc
 pflusha
 move.l #${'80008000' if cached else '0'},d0
 movec d0,cacr
 moveq #0,d6
 move.w #0,ccr
 {instruction}
 move.w ccr,d7
 {leak}
 move.w d7,($350c).l
 move.w d6,($350e).l
 moveq #0,d0
 move.{size} ({address}).l,d0
 move.l d0,($3504).l
 move.l #{expected},($3508).l
 cmpi.l #{expected},d0
 bne fail
 cmpi.w #{int(fault)},($3500).l
 bne fail
 {checks}
 move.w #$600d,($f102).l
 bra.s *
fail:
 move.w #1,($f100).l
 move.w #$bad0,($f102).l
 bra.s *
handler:
 move.w ccr,d7
 move.w (sp),d6
 move.w d7,($3510).l
 move.w d6,($3512).l
 move.l #$8003,($4420).l
 pflusha
 addq.w #1,($3500).l
 rte
"""


def split_control(core):
    old = "if (m_bidx + 3'd1 == m_nbytes) state <= r_m_ret;"
    section = core.split("S_MWR_B: begin", 1)[1].split("S_NEXT: fetch_next;", 1)[0]
    if old not in core and "if (fl_pend) begin sr[4:0] <= fl_pend_v; fl_pend <= 0; end" in section:
        return core  # The concurrent split-completion fix is already present.
    assert core.count(old) == 1, "split completion changed; review diagnostic control"
    return core.replace(old, """if (m_bidx + 3'd1 == m_nbytes) begin
                        if (fl_pend) begin sr[4:0] <= fl_pend_v; fl_pend <= 0; end
                        state <= r_m_ret;
                    end""")


def abort_control(core):
    old = "task aerr_start;\n\tbegin"
    assert core.count(old) == 1, "access-error entry changed; review diagnostic control"
    if "fl_pend <= 0;" in core.split(old, 1)[1].split("endtask", 1)[0]:
        return core
    return core.replace(old, old + "\n\t\tfl_pend <= 0;")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work", type=Path, default=Path("/tmp/ap040-deferred-flags-audit"))
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--expect-defects", action="store_true")
    parser.add_argument("--diagnostic-controls", action="store_true")
    args = parser.parse_args()
    work = args.work.resolve()
    work.mkdir(parents=True, exist_ok=True)
    snapshot = work / "source"
    snapshot.mkdir(exist_ok=True)
    inputs = [HERE / "tb_ap040_program.v", HERE / "sim_dpram.v",
              *sorted(AP.glob("*.v")), *sorted(AP.glob("*.svh")), ROOT / "rtl/memory_router.v"]
    hashes = {}
    for path in inputs:
        data = path.read_bytes()
        (snapshot / path.name).write_bytes(data)
        hashes[str(path.relative_to(ROOT))] = hashlib.sha256(data).hexdigest()
    (work / "source_sha256.json").write_text(json.dumps(hashes, indent=2) + "\n")
    (work / "git-head.txt").write_text(subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True))
    bench = (snapshot / "tb_ap040_program.v").read_text()
    marker = "if (addr_out[15:0] == 16'hF102 && !nuds && !nlds) begin"
    assert bench.count(marker) == 1
    bench = bench.replace(marker, marker + """
 $display("AUDIT result=%h%h expected=%h%h faults=%0d ccr=%h after_st=%h handler_ccr=%h frame_sr=%h", mem[16'h3504>>1], mem[16'h3506>>1], mem[16'h3508>>1], mem[16'h350a>>1], mem[16'h3500>>1], mem[16'h350c>>1], mem[16'h350e>>1], mem[16'h3510>>1], mem[16'h3512>>1]);
""", 1)
    bench_path = work / "tb_ap040_program.v"
    bench_path.write_text(bench)
    images = []
    for case in ("add", "shift", "leak", "entry_negx", "entry_roxl"):
        for mode in (("aligned",) if case.startswith("entry_") else ("cross", "aligned", "tc0")):
            for cached in (False, True):
                name = f"{case}-{mode}-cache{int(cached)}"
                asm, binary, image = [work / (name + ext) for ext in (".s", ".bin", ".hex")]
                asm.write_text(program(case, mode, cached))
                run([os.environ.get("VASM", "/opt/amiga-cc/vbcc/bin/vasmm68k_mot"),
                     "-quiet", "-Fbin", "-m68040", "-no-opt", "-o", binary, asm], work / (name + ".assemble.log"))
                data = binary.read_bytes()
                assert len(data) < 65536 and len(data) % 2 == 0
                image.write_text("".join(data[i:i+2].hex() + "\n" for i in range(0, len(data), 2)))
                images.append((name, image, case, mode, cached))
    core = (snapshot / "ap040_core.v").read_text()
    variants = {"production": core}
    if args.diagnostic_controls:
        variants.update(split_only=split_control(core), both=abort_control(split_control(core)))
    sources = [snapshot / "sim_dpram.v", *[snapshot / p.name for p in sorted(AP.glob("*.v"))
               if p.name != "ap040_core.v"], snapshot / "memory_router.v"]
    results = []
    for variant, source in variants.items():
        core_path = work / f"core-{variant}.v"
        core_path.write_text(source)
        for posted in (False, True):
            tag = f"{variant}-post{int(posted)}"
            obj = work / ("obj-" + tag)
            run(["verilator", "--binary", "--timing", "--top-module", "tb_ap040_program",
                 "--Mdir", obj, "-j", args.jobs, "-Wno-fatal", "-I" + str(snapshot),
                 f"-GPOST_STORES={int(posted)}", bench_path, core_path, *sources], work / ("compile-" + tag + ".log"))
            for name, image, case, mode, cached in images:
                log = work / f"{tag}-{name}.log"
                run([obj / "Vtb_ap040_program", "+prog=" + str(image)], log)
                output = log.read_text()
                samples = re.findall(r"AUDIT result=(\w+) expected=(\w+) faults=(\d+) ccr=(\w+) after_st=(\w+) handler_ccr=(\w+) frame_sr=(\w+)", output)
                assert len(samples) == 3, f"missing handshake-phase result: {log}"
                assert all(int(s[2]) == int(case.startswith("entry_")) for s in samples), f"unexpected fault count: {log}"
                passed = "ALL TESTS PASSED" in output and not re.search(r"FAIL:|TEST FAILED|%Error", output)
                result = dict(variant=variant, case=case, mode=mode, posted=posted,
                              cached=cached, passed=passed, samples=samples, log=str(log))
                results.append(result)
                print(f"{tag} {name}: {'PASS' if passed else 'FAIL'} ccr={samples[0][3]} after_st={samples[0][4]} handler={samples[0][5]} frame={samples[0][6]}", flush=True)
            (work / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    if args.expect_defects:
        for result in results:
            defect = ((result["mode"] == "cross" and result["variant"] == "production") or
                      (result["case"].startswith("entry_") and result["variant"] != "both"))
            assert result["passed"] != defect, f"audit matrix changed: {result}"
        print("Observed audit matrix confirmed (known production failures, passing controls).")
    elif not all(r["passed"] for r in results):
        raise SystemExit("Deferred CCR failures: see results.json")


if __name__ == "__main__":
    main()
