#!/usr/bin/env python3
"""Export packed cputest DIV corpora into fixed-width wrapper replay assets.

This exporter is intentionally narrow:
- 68030 DIVL.L and DIVU.W suites only
- original 0x420xxxxx / 0x430xxxxx address layout preserved
- one fixed-width case record per execution group/subcase

Outputs:
- <prefix>.low.mem    : low-memory image (word-per-line hex)
- <prefix>.high0.mem  : test-memory image at 0x42000000 (word-per-line hex)
- <prefix>.cases.mem  : fixed-width 32-bit case records (word-per-line hex)
"""

from __future__ import annotations

import argparse
import gzip
from pathlib import Path

from decode_cputest_dat import CT_AREG, CT_DREG, parse_case_file, parse_header


LOW_BYTES = 0x8000
HIGH0_BYTES = 0xA0000
OPC_BASE = 0x42050000
MAX_PATCH_BYTES = 12
MAX_EXPECTED = 5
CASE_WORDS = 32


KEY_TO_CODE = {
    "SR": 0,
    "PC": 1,
    **{f"D{i}": 2 + i for i in range(8)},
    **{f"A{i}": 10 + i for i in range(8)},
}


def emit_word_lines(words: list[int], out_path: Path) -> None:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w", encoding="ascii") as f:
        for word in words:
            f.write(f"{word & 0xFFFF:04X}\n")


def emit_case_lines(words: list[int], out_path: Path) -> None:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w", encoding="ascii") as f:
        for word in words:
            f.write(f"{word & 0xFFFFFFFF:08X}\n")


def build_opcode_patch_bytes(subcase) -> bytes:
    patch = bytearray()

    for bytepatch in subcase.init_bytepatches:
        if bytepatch.addr < OPC_BASE or bytepatch.addr >= OPC_BASE + MAX_PATCH_BYTES:
            raise ValueError(f"unexpected opcode patch base {hex(bytepatch.addr)}")
        offset = bytepatch.addr - OPC_BASE
        while len(patch) < offset:
            patch.append(0)
        end = offset + len(bytepatch.data)
        while len(patch) < end:
            patch.append(0)
        patch[offset:end] = bytepatch.data

    for memwrite in subcase.init_memwrites:
        if memwrite.addr < OPC_BASE or memwrite.addr >= OPC_BASE + MAX_PATCH_BYTES:
            raise ValueError(f"unexpected init memwrite outside opcode window: {hex(memwrite.addr)}")
        offset = memwrite.addr - OPC_BASE
        while len(patch) <= offset + memwrite.size:
            patch.append(0)
        if memwrite.size == 0:
            patch[offset] = memwrite.new & 0xFF
        elif memwrite.size == 1:
            patch[offset] = (memwrite.new >> 8) & 0xFF
            patch[offset + 1] = memwrite.new & 0xFF
        elif memwrite.size == 2:
            patch[offset] = (memwrite.new >> 24) & 0xFF
            patch[offset + 1] = (memwrite.new >> 16) & 0xFF
            patch[offset + 2] = (memwrite.new >> 8) & 0xFF
            patch[offset + 3] = memwrite.new & 0xFF
        else:
            raise ValueError(f"unsupported memwrite size {memwrite.size}")

    if len(patch) == 0:
        raise ValueError("empty opcode patch")
    if len(patch) > MAX_PATCH_BYTES:
        raise ValueError(f"opcode patch too large: {len(patch)} bytes")
    return bytes(patch)


def patch_words_from_bytes(data: bytes) -> list[int]:
    padded = data + b"\x00" * (MAX_PATCH_BYTES - len(data))
    out = []
    for offs in range(0, MAX_PATCH_BYTES, 4):
        out.append(int.from_bytes(padded[offs:offs + 4], "big"))
    return out


def sr_from_extraccr(extraccr: int) -> int:
    sr_mask = 0
    if extraccr & 1:
        sr_mask |= 0x2000
    if extraccr & 2:
        sr_mask |= 0x4000
    if extraccr & 4:
        sr_mask |= 0x8000
    if extraccr & 8:
        sr_mask |= 0x1000
    return sr_mask


def initial_sr_from_group(subcase, state: dict[str, int]) -> int:
    maxccr = subcase.ccrmode & 0x3F
    sr_val = state.get("SR", 0) & 0xFFFF
    if maxccr >= 32:
        sr_val = (sr_val & 0xFF00) | (subcase.ccr & 0xFF)
    elif (subcase.ccr & 1) == 1:
        sr_val = (sr_val & 0xFFE0) | 0x001F
    sr_val |= sr_from_extraccr(subcase.extraccr)
    return sr_val & 0xFFFF


def export_suite(suite_dir: Path, out_prefix: Path) -> None:
    header = parse_header(suite_dir / "0000.dat")
    suite_root = suite_dir.parent

    if header.opcode_memory_addr != OPC_BASE:
        raise ValueError(f"unexpected opcode base {hex(header.opcode_memory_addr)}")
    if header.test_memory_addr != 0x42000000:
        raise ValueError(f"unexpected test base {hex(header.test_memory_addr)}")
    if header.test_memory_size != HIGH0_BYTES:
        raise ValueError(f"unexpected test size {hex(header.test_memory_size)}")

    lmem = gzip.open(suite_root / "lmem.dat.gz", "rb").read()
    tmem = gzip.open(suite_root / "tmem.dat.gz", "rb").read()

    low_words: list[int] = []
    for offs in range(0, LOW_BYTES, 2):
        hi = lmem[offs] if offs < len(lmem) else 0
        lo = lmem[offs + 1] if offs + 1 < len(lmem) else 0
        low_words.append((hi << 8) | lo)

    high0_words: list[int] = []
    for offs in range(0, HIGH0_BYTES, 2):
        hi = tmem[offs] if offs < len(tmem) else 0
        lo = tmem[offs + 1] if offs + 1 < len(tmem) else 0
        high0_words.append((hi << 8) | lo)

    case_words: list[int] = [0]
    case_count = 0

    for case_file in sorted(suite_dir.glob("*.dat.gz")):
        _header, parser = parse_case_file(case_file)
        for subcase, state in parser.iter_subcases():
            patch_bytes = build_opcode_patch_bytes(subcase)
            patch_words = patch_words_from_bytes(patch_bytes)

            expected_items = sorted(subcase.expected_values.items())
            if len(expected_items) > MAX_EXPECTED:
                raise ValueError(f"too many expected values: {len(expected_items)}")

            rec = [0] * CASE_WORDS
            instr_len = (state.get("ENDPC", OPC_BASE) - state.get("PC", OPC_BASE)) & 0xFF
            rec[0] = (
                ((subcase.exc & 0xFF) << 0)
                | ((len(patch_bytes) & 0xFF) << 8)
                | ((len(expected_items) & 0xFF) << 16)
                | ((instr_len & 0xFF) << 24)
            )
            rec[1] = 0xFFFFFFFF if subcase.expected_sr_ignore_mask is None else (subcase.expected_sr_ignore_mask & 0xFFFF)

            for i in range(8):
                rec[2 + i] = state.get(f"D{i}", 0) & 0xFFFFFFFF
                rec[10 + i] = state.get(f"A{i}", 0) & 0xFFFFFFFF

            rec[18:21] = patch_words
            rec[21] = initial_sr_from_group(subcase, state)

            for i, (key, value) in enumerate(expected_items):
                code = KEY_TO_CODE.get(key)
                if code is None:
                    raise ValueError(f"unsupported expected key {key}")
                rec[22 + i * 2] = code
                rec[23 + i * 2] = value & 0xFFFFFFFF

            case_words.extend(rec)
            case_count += 1

    case_words[0] = case_count

    emit_word_lines(low_words, out_prefix.with_suffix(".low.mem"))
    emit_word_lines(high0_words, out_prefix.with_suffix(".high0.mem"))
    emit_case_lines(case_words, out_prefix.with_suffix(".cases.mem"))


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("suite_dir", type=Path, help="Suite directory like .../68030_Default/DIVL.L")
    ap.add_argument("--out-prefix", type=Path, required=True, help="Output prefix path without extension")
    args = ap.parse_args()
    export_suite(args.suite_dir, args.out_prefix)


if __name__ == "__main__":
    main()
