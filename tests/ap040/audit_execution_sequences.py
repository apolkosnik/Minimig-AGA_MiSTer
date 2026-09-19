#!/usr/bin/env python3
"""Audit normal-execution dependencies against bit/byte and integer models.

Runs bitfield register aliases and memory modifications, chained ADDX/SUBX,
and self-modifying code with cache maintenance. No faults are expected.
The RTL and bench are frozen before compilation; production is not edited.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import random
import re
import subprocess

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
AP = ROOT / "rtl/ap040"
MASK = 0xffffffff


def run(command, log):
    with log.open("w") as stream:
        subprocess.run([str(x) for x in command], cwd=ROOT, stdout=stream,
                       stderr=subprocess.STDOUT, check=True, timeout=300)


def check(reg, value, size="l"):
    return f"cmpi.{size} #${value & MASK:x},{reg}\n bne fail\n"


def bits(value, width):
    return [(value >> n) & 1 for n in range(width - 1, -1, -1)]


def number(values):
    out = 0
    for bit in values:
        out = out * 2 + bit
    return out


def bitfields(seed, memory):
    rng = random.Random(seed)
    image = [rng.randrange(256) for _ in range(32)]
    operand = rng.getrandbits(32)
    base = 0x7ff0
    out = ""
    if memory:
        for i in range(0, 32, 4):
            out += f"move.l #${int.from_bytes(bytes(image[i:i+4]), 'big'):x},(${base+i:x}).l\n"
        out += "lea ($7ff8).l,a0\n"
        # Warm all words: subsequent writes must update/invalidate hits.
        for i in range(0, 32, 4):
            out += f"move.l (${base+i:x}).l,d6\n"
    for step, op in enumerate(("bftst", "bfextu", "bfchg", "bfexts", "bfclr", "bfffo", "bfset", "bfins")):
        offset = rng.randint(-31, 31) if memory else rng.getrandbits(32)
        width = (1, 7, 8, 9, 16, 17, 31, 32)[(seed + step) % 8]
        x = (seed + step) & 1
        insert = rng.getrandbits(32) if memory else operand
        values = [b for byte in image for b in bits(byte, 8)] if memory else bits(operand, 32)
        indices = [64 + offset + i if memory else (offset + i) % 32 for i in range(width)]
        field = [values[i] for i in indices]
        result = number(field)
        flag_field = bits(insert & ((1 << width) - 1), width) if op == "bfins" else field
        ccr = x * 16 + flag_field[0] * 8 + (4 if not any(flag_field) else 0)
        dest = "d1" if step & 1 else "d0"  # extraction may overwrite offset/base
        out += f"move.w #{step+1},($f100).l\nmove.l #${offset & MASK:x},d1\nmove.l #{width % 32},d2\n"
        out += f"move.l #${insert if memory else operand:x},d0\nmove.w #{x*16},ccr\n"
        ea = "(a0)" if memory else "d0"
        spec = f"{ea}{{d1:d2}}"
        ins = f"bfins d0,{spec}" if op == "bfins" else f"{op} {spec}"
        if op in ("bfextu", "bfexts", "bfffo"):
            ins += "," + dest
        out += ins + "\nmove.w ccr,d7\n" + check("d7", ccr, "w")
        if op == "bfexts" and field[0]:
            result |= MASK ^ ((1 << width) - 1)
        if op == "bfffo":
            # Zero-field result is not used as an oracle: only CCR is checked.
            result = offset + field.index(1) if any(field) else None
        if op in ("bfextu", "bfexts", "bfffo"):
            if result is not None:
                out += check(dest, result)
            if not memory and dest == "d0":
                operand = result if result is not None else 0
                if result is None:
                    out += "moveq #0,d0\n"
        else:
            replacement = ([1 - b for b in field] if op == "bfchg" else [0] * width if op == "bfclr"
                           else [1] * width if op == "bfset" else flag_field if op == "bfins" else field)
            for i, bit in zip(indices, replacement):
                values[i] = bit
            if memory:
                image = [number(values[i:i+8]) for i in range(0, len(values), 8)]
            else:
                operand = number(values)
                out += check("d0", operand)
        if memory:
            for i in range(0, 32, 4):
                out += check(f"(${base+i:x}).l", int.from_bytes(bytes(image[i:i+4]), "big"))
    return out


def carry_chain(seed, memory):
    rng = random.Random(seed ^ 0x040)
    width = (8, 16, 32)[seed % 3]
    size = {8: "b", 16: "w", 32: "l"}[width]
    mask = (1 << width) - 1
    src = [rng.getrandbits(32) for _ in range(4)]
    dst = [rng.getrandbits(32) for _ in range(4)]
    if seed % 4 == 0:
        src, dst = [0] * 4, [mask] * 4
    elif seed % 4 == 1:
        src, dst = [0] * 4, [0] * 4
    subtract = bool(seed & 2)
    x, z = seed & 1, bool(seed & 4)
    out = ""
    nb = width // 8
    for i in range(4):
        if memory:
            out += f"move.{size} #${src[i] & mask:x},(${0x7ff8+(3-i)*nb:x}).l\n"
            out += f"move.{size} #${dst[i] & mask:x},(${0x80f8+(3-i)*nb:x}).l\n"
        else:
            out += f"move.l #${dst[i]:x},d{i}\nmove.l #${src[i]:x},d{i+4}\n"
    if memory:
        out += f"lea (${0x7ff8+4*nb:x}).l,a0\nlea (${0x80f8+4*nb:x}).l,a1\n"
    out += f"move.w #{x*16+int(z)*4},ccr\n"
    expected = []
    for i in range(4):
        a, b = dst[i] & mask, src[i] & mask
        full = a - b - x if subtract else a + b + x
        value = full & mask
        sign = 1 << (width - 1)
        signed_a, signed_b = (a - (1 << width) if a & sign else a), (b - (1 << width) if b & sign else b)
        signed_result = signed_a - signed_b - x if subtract else signed_a + signed_b + x
        v = not (-sign <= signed_result < sign)
        x = int(full < 0 if subtract else full > mask)
        z = z and value == 0
        ccr = x * 17 + (8 if value & sign else 0) + int(z) * 4 + int(v) * 2
        expected.append(value if memory else (dst[i] & ~mask) | value)
        op = "subx" if subtract else "addx"
        out += f"{op}.{size} " + ("-(a0),-(a1)" if memory else f"d{i+4},d{i}") + "\n"
    out += "move.w ccr,d7\n" + check("d7", ccr, "w")
    for i, value in enumerate(expected):
        out += check(f"(${0x80f8+(3-i)*nb:x}).l" if memory else f"d{i}", value, size if memory else "l")
    if memory:
        out += "move.l a0,d0\n" + check("d0", 0x7ff8)
        out += "move.l a1,d0\n" + check("d0", 0x80f8)
    return out


def smc():
    return """jsr target
 cmpi.l #1,d0
 bne fail
 move.w #$7002,target
 cpusha dc
 cinva ic
 jsr target
 cmpi.l #2,d0
 bne fail
 move.w #$7003,adjacent
 cinva ic
adjacent:
 moveq #1,d0
 cmpi.l #3,d0
 bne fail
 bra smc_done
target:
 moveq #1,d0
 rts
smc_done:
"""


def program(body, cached, page):
    pg = page or 4096
    setup = f"""lea ($4400).l,a0
 moveq #0,d0
 moveq #{65536//pg-1},d1
tables:
 move.l d0,d2
 ori.l #3,d2
 move.l d2,(a0)+
 addi.l #{pg},d0
 dbra d1,tables
 move.l #$4203,($4000).l
 move.l #$4403,($4200).l
 move.l #$4000,d0
 movec d0,srp
 movec d0,urp
 move.l #${0xc000 if page == 8192 else 0x8000 if page else 0:x},d0
 movec d0,tc
 pflusha
 move.l #${0x80008000 if cached else 0:x},d0
 movec d0,cacr
"""
    source = " org 0\n dc.l $3400,start\n rept 62\n dc.l fail\n endr\n org $400\nstart:\n" + setup + body + """
 move.w #$600d,($f102).l
 bra.s *
fail:
 move.w #$bad0,($f102).l
 bra.s *
"""
    return "\n".join(line.strip() if line.strip().endswith(":") else " " + line.strip()
                     for line in source.splitlines()) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work", type=Path, default=Path("/tmp/ap040-execution-audit"))
    parser.add_argument("--seeds", type=int, default=16)
    parser.add_argument("--jobs", type=int, default=4)
    args = parser.parse_args()
    work = args.work.resolve()
    snap = work / "source"
    snap.mkdir(parents=True, exist_ok=True)
    inputs = [HERE / "tb_ap040_program.v", HERE / "sim_dpram.v", ROOT / "rtl/memory_router.v",
              *sorted(AP.glob("*.v")), *sorted(AP.glob("*.svh"))]
    hashes = {}
    for path in inputs:
        data = path.read_bytes()
        (snap / path.name).write_bytes(data)
        hashes[str(path.relative_to(ROOT))] = hashlib.sha256(data).hexdigest()
    (work / "source_sha256.json").write_text(json.dumps(hashes, indent=2) + "\n")
    (work / "git-head.txt").write_text(subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True))
    cases = [(f"{kind}-{seed}", fn(seed, memory)) for seed in range(args.seeds)
             for kind, fn, memory in (("bf_reg", bitfields, False), ("bf_mem", bitfields, True),
                                     ("carry_reg", carry_chain, False), ("carry_mem", carry_chain, True))]
    cases.append(("smc", smc()))
    images = []
    for name, body in cases:
        for cached in (False, True):
            for page in (0, 4096, 8192):
                tag = f"{name}-cache{int(cached)}-page{page}"
                asm, binary, image = [work / (tag + suffix) for suffix in (".s", ".bin", ".hex")]
                asm.write_text(program(body, cached, page))
                run([os.environ.get("VASM", "/opt/amiga-cc/vbcc/bin/vasmm68k_mot"), "-quiet", "-Fbin",
                     "-m68040", "-no-opt", "-o", binary, asm], work / (tag + ".assemble.log"))
                data = binary.read_bytes()
                assert len(data) < 0x3000 and len(data) % 2 == 0, tag
                image.write_text("".join(data[i:i+2].hex() + "\n" for i in range(0, len(data), 2)))
                images.append((tag, image))
    results = []
    for posted in (0, 1):
        obj = work / f"obj-post{posted}"
        run(["verilator", "--binary", "--timing", "--top-module", "tb_ap040_program",
             "--Mdir", obj, "-j", args.jobs, "-Wno-fatal", "-I" + str(snap), f"-GPOST_STORES={posted}",
             *[snap / p.name for p in inputs if p.suffix == ".v"]], work / f"compile-post{posted}.log")
        for tag, image in images:
            log = work / f"post{posted}-{tag}.log"
            run([obj / "Vtb_ap040_program", "+prog=" + str(image)], log)
            txt = log.read_text()
            passed = "ALL TESTS PASSED" in txt and not re.search(r"FAIL:|TEST FAILED|%Error", txt)
            results.append(dict(case=tag, posted=posted, passed=passed, log=str(log)))
            if not passed:
                print(f"FAIL post{posted} {tag}: {log}", flush=True)
        (work / "results.json").write_text(json.dumps(results, indent=2) + "\n")
        rows = [r for r in results if r["posted"] == posted]
        print(f"post{posted}: {sum(r['passed'] for r in rows)}/{len(rows)} cases pass (three phases each)", flush=True)
    if not all(r["passed"] for r in results):
        raise SystemExit("Execution sequence audit failed: see results.json")


if __name__ == "__main__":
    main()
