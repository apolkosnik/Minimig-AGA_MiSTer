#!/usr/bin/env python3
"""Audit write-fault restart with real MMU faults and a repairing RTE handler.

No production RTL is changed. Builds use the existing core bench, augmented
only with result logging. Generates no-fault controls and diagnostic controls
that restore the known input CCR in the stacked frame. --expect-defects checks
the audit's observed matrix; without it any failing program exits nonzero.
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
CASES = {
    "negx": ("move.l #1,($8000).l", "negx.l ($8000).l",
             "move.l ($8000).l,d0", "$ffffffff", "$8000"),
    "roxl": ("move.w #$8000,($8000).l", "roxl.w ($8000).l",
             "moveq #0,d0\n move.w ($8000).l,d0", "0", "$8000"),
    "cross_add": ("move.l #0,($7fff).l", "add.l #$01000000,($7fff).l",
                  "move.l ($7fff).l,d0", "$01000000", "$7fff"),
    "cross_bfchg": ("move.l #0,($7ffe).l", "bfchg ($7ffe).l{0:32}",
                    "move.l ($7ffe).l,d0", "$ffffffff", "$7ffe"),
    "cas2": ("move.l #1,($7000).l\n move.l #2,($8000).l",
             "moveq #1,d0\n moveq #2,d1\n moveq #17,d2\n moveq #34,d3\n"
             " lea ($7000).l,a0\n lea ($8000).l,a1\n cas2.l d0:d1,d2:d3,(a0):(a1)",
             "move.l ($8000).l,d0", "$22", "$7000"),
}


def run(command, log):
    with log.open("w") as out:
        subprocess.run([str(x) for x in command], cwd=ROOT, stdout=out,
                       stderr=subprocess.STDOUT, check=True, timeout=300)


def program(case, fault, cached, restore):
    init, instruction, read, expected, capture = CASES[case]
    # An explicit PFLUSHA is necessary: the bench resets between handshake
    # phases, but hardware warm reset intentionally preserves the ATC.
    return f""" org 0
 dc.l $3400,start,handler
 org $400
start:
 clr.w ($3500).l
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
 {init}
 move.l #${'8007' if fault else '8003'},($4420).l
 move.l #$4000,d0
 movec d0,srp
 movec d0,urp
 move.l #$8000,d0
 movec d0,tc
 pflusha
 move.l #${'80008000' if cached else '0'},d0
 movec d0,cacr
 move.w #0,ccr
 {instruction}
 move.w ccr,($350e).l
 {read}
 move.l d0,($3504).l
 move.l #{expected},($3508).l
 cmp.l #{expected},d0
 bne fail
 cmpi.w #{int(fault)},($3500).l
 bne fail
 {'cmpi.l #17,($7000).l' if case == 'cas2' else 'nop'}
 {'bne fail' if case == 'cas2' else 'nop'}
 move.w #$600d,($f102).l
 bra.s *
fail:
 move.w #1,($f100).l
 move.w #$bad0,($f102).l
 bra.s *
handler:
 move.w (sp),($3510).l
 move.l 2(sp),($3514).l
 move.l ({capture}).l,($3520).l
 move.l #$8003,($4420).l
 pflusha
 addq.w #1,($3500).l
 {'andi.w #$ffe0,(sp)' if restore else '; preserve the core-generated frame'}
 rte
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work", type=Path, default=Path("/tmp/ap040-restart-audit"))
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--expect-defects", action="store_true")
    args = parser.parse_args()
    work = args.work.resolve()
    work.mkdir(parents=True, exist_ok=True)
    bench = (HERE / "tb_ap040_program.v").read_text()
    marker = "if (addr_out[15:0] == 16'hF102 && !nuds && !nlds) begin"
    assert bench.count(marker) == 1
    bench = bench.replace(marker, marker + """
 $display("AUDIT result=%h%h expected=%h%h faults=%0d frame_sr=%h final_ccr=%h before_repair=%h%h", mem[16'h3504>>1], mem[16'h3506>>1], mem[16'h3508>>1], mem[16'h350a>>1], mem[16'h3500>>1], mem[16'h3510>>1], mem[16'h350e>>1], mem[16'h3520>>1], mem[16'h3522>>1]);
""", 1)
    bench_path = work / "tb_ap040_program.v"
    bench_path.write_text(bench)
    sources = [HERE / "sim_dpram.v", *sorted(AP.glob("*.v")), ROOT / "rtl/memory_router.v"]
    (work / "source_sha256.json").write_text(json.dumps({str(p.relative_to(ROOT)):
        hashlib.sha256(p.read_bytes()).hexdigest() for p in [HERE / "tb_ap040_program.v", *sources]}, indent=2) + "\n")
    images = []
    for case in CASES:
        for cached in (False, True):
            modes = [(False, False), (True, False)]
            if case in ("negx", "roxl"):
                modes.append((True, True))
            for fault, restore in modes:
                name = f"{case}-cache{int(cached)}-fault{int(fault)}-restore{int(restore)}"
                asm, binary, image = [work / (name + ext) for ext in (".s", ".bin", ".hex")]
                asm.write_text(program(case, fault, cached, restore))
                run([os.environ.get("VASM", "/opt/amiga-cc/vbcc/bin/vasmm68k_mot"),
                     "-quiet", "-Fbin", "-m68040", "-no-opt", "-o", binary, asm], work / (name + ".assemble.log"))
                data = binary.read_bytes()
                assert len(data) < 65536 and len(data) % 2 == 0
                image.write_text("".join(data[i:i+2].hex() + "\n" for i in range(0, len(data), 2)))
                images.append((name, image, case, cached, fault, restore))
    results = []
    for posted in (False, True):
        obj = work / f"obj-post{int(posted)}"
        run(["verilator", "--binary", "--timing", "--top-module", "tb_ap040_program",
             "--Mdir", obj, "-j", args.jobs, "-Wno-fatal", "-I" + str(AP),
             f"-GPOST_STORES={int(posted)}", bench_path, *sources], work / f"compile-post{int(posted)}.log")
        for name, image, case, cached, fault, restore in images:
            log = work / f"post{int(posted)}-{name}.log"
            run([obj / "Vtb_ap040_program", "+prog=" + str(image)], log)
            output = log.read_text()
            samples = re.findall(r"AUDIT result=(\w+) expected=(\w+) faults=(\d+) frame_sr=(\w+) final_ccr=(\w+) before_repair=(\w+)", output)
            assert len(samples) == 3, f"missing handshake-phase result: {log}"
            assert all(int(s[2]) == int(fault) for s in samples), f"unexpected fault count: {log}"
            passed = "ALL TESTS PASSED" in output and "FAIL:" not in output
            results.append(dict(case=case, posted=posted, cached=cached, fault=fault,
                                restore_ccr=restore, passed=passed, samples=samples, log=str(log)))
            print(f"post{int(posted)} {name}: {'PASS' if passed else 'FAIL'} result={samples[0][0]} expected={samples[0][1]}", flush=True)
    (work / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    if args.expect_defects:
        assert all(r["passed"] == (not r["fault"] or r["restore_ccr"]) for r in results), "audit matrix changed; inspect results"
        print("Observed matrix confirmed: 20 faulty restart cases; 28 no-fault/CCR controls pass.")
    elif not all(r["passed"] for r in results):
        raise SystemExit("Write-fault restart failures: see results.json")


if __name__ == "__main__":
    main()
