#!/usr/bin/env python3
"""Inspect packed WinUAE cputest .dat/.dat.gz records.

This helper is aimed at the cumulative 68020+ BASIC data files where a single
packed testcase can contain many init-record deltas and many per-CCR subcases.
It is intentionally diagnostic-focused:

- tracks cumulative init-register state across records
- decodes per-subcase override records
- locates expected memwrite checks by absolute address
- prints the surrounding cumulative state for matching subcases

It does not attempt to emulate the whole cputest runtime.
"""

from __future__ import annotations

import argparse
import gzip
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Sequence, Tuple


DATA_VERSIONS = {20, 24}

CT_DREG = 0
CT_AREG = 8
CT_SSP = 16
CT_MSP = 17
CT_SR = 18
CT_PC = 19
CT_FPIAR = 20
CT_FPSR = 21
CT_FPCR = 22
CT_EDATA = 23
CT_CYCLES = 25
CT_ENDPC = 26
CT_BRANCHTARGET = 27
CT_SRCADDR = 28
CT_DSTADDR = 29
CT_MEMWRITE = 30
CT_MEMWRITES = 31
CT_DATA_MASK = 31
CT_EXCEPTION_MASK = 63

CT_SIZE_BYTE = 0 << 5
CT_SIZE_WORD = 1 << 5
CT_SIZE_LONG = 2 << 5
CT_SIZE_FPU = 3 << 5
CT_SIZE_MASK = 3 << 5

CT_RELATIVE_START_WORD = 0 << 5
CT_ABSOLUTE_WORD = 1 << 5
CT_ABSOLUTE_LONG = 2 << 5
CT_PC_BYTES = 3 << 5
CT_RELATIVE_START_BYTE = 3 << 5

CT_END = 0x80
CT_END_FINISH = 0xFF
CT_END_INIT = 0xC0
CT_END_SKIP = 0xC1
CT_OVERRIDE_REG = 0xD0


REG_NAMES = {
    **{CT_DREG + i: f"D{i}" for i in range(8)},
    **{CT_AREG + i: f"A{i}" for i in range(8)},
    CT_SSP: "SSP",
    CT_MSP: "MSP",
    CT_SR: "SR",
    CT_PC: "PC",
    CT_FPIAR: "FPIAR",
    CT_FPSR: "FPSR",
    CT_FPCR: "FPCR",
    CT_CYCLES: "CYCLES",
    CT_ENDPC: "ENDPC",
    CT_BRANCHTARGET: "BRANCHTARGET",
    CT_SRCADDR: "SRCADDR",
    CT_DSTADDR: "DSTADDR",
}

STATE_KEYS = ("D0", "D1", "D2", "D3", "D6", "D7", "A1", "A3", "A4", "A7", "SR", "PC", "ENDPC", "SRCADDR", "BRANCHTARGET")


def gl(buf: bytes, off: int) -> int:
    return int.from_bytes(buf[off:off + 4], "big")


@dataclass
class Header:
    test_memory_addr: int
    test_memory_size: int
    opcode_memory_addr: int
    interrupttest: int
    user_stack_memory: int
    super_stack_memory: int


@dataclass
class MemWrite:
    addr: int
    size: int
    old: int
    new: int


@dataclass
class Subcase:
    record_index: int
    group_index: int
    subcase_index: int
    extraccr: int
    ccrmode: int
    ccr: int
    overrides: List[Tuple[str, int]] = field(default_factory=list)
    memwrites: List[MemWrite] = field(default_factory=list)
    end_marker: int = 0
    exc: int = 0
    branched: bool = False
    extra_trace: int = 0
    extra_trace_standalone: bool = False
    group2_with_1: int = -1


class Parser:
    def __init__(self, header: Header, data: bytes) -> None:
        self.header = header
        self.data = data[16:]
        self.state: Dict[str, int] = {
            "SR": 0,
            "PC": header.opcode_memory_addr,
            "ENDPC": header.opcode_memory_addr,
            "BRANCHTARGET": 0xFFFFFFFF,
            "BRANCHTARGET_MODE": 0,
            "SRCADDR": 0,
            "DSTADDR": 0,
            "FPIAR": 0xFFFFFFFF,
            "FPCSR": 0,
        }

    def restore_value(self, off: int, cur: int = 0) -> Tuple[int, int, int]:
        tag = self.data[off]
        off += 1
        size_sel = tag & CT_SIZE_MASK
        if size_sel == CT_SIZE_BYTE:
            return off + 1, (cur & 0xFFFFFF00) | self.data[off], 0
        if size_sel == CT_SIZE_WORD:
            return off + 2, (cur & 0xFFFF0000) | int.from_bytes(self.data[off:off + 2], "big"), 1
        if size_sel == CT_SIZE_LONG:
            return off + 4, gl(self.data, off), 2
        raise ValueError(f"unexpected restore_value size {size_sel:02x} at {off - 1:04x}")

    def restore_rel(self, off: int, cur: int = 0) -> Tuple[int, int]:
        tag = self.data[off]
        off += 1
        size_sel = tag & CT_SIZE_MASK
        if size_sel == CT_RELATIVE_START_BYTE:
            delta = int.from_bytes(self.data[off:off + 1], "big", signed=True)
            return off + 1, (cur + delta) & 0xFFFFFFFF
        if size_sel == CT_RELATIVE_START_WORD:
            delta = int.from_bytes(self.data[off:off + 2], "big", signed=True)
            return off + 2, (cur + delta) & 0xFFFFFFFF
        if size_sel == CT_ABSOLUTE_WORD:
            return off + 2, int.from_bytes(self.data[off:off + 2], "big", signed=True) & 0xFFFFFFFF
        if size_sel == CT_ABSOLUTE_LONG:
            return off + 4, gl(self.data, off)
        raise ValueError(f"unexpected restore_rel size {size_sel:02x} at {off - 1:04x}")

    def parse_fpvalue(self, off: int) -> int:
        tag = self.data[off]
        off += 1
        if (tag & CT_SIZE_MASK) != CT_SIZE_FPU:
            raise ValueError(f"expected CT_SIZE_FPU at {off - 1:04x}")
        size = self.data[off]
        off += 1
        if size == 0x00:
            return off
        if size == 0xFF:
            return off + 10
        size1 = (size >> 4) & 0xF
        size2 = size & 0xF
        return off + size1 + size2

    def parse_mem_addr(self, off: int) -> Tuple[int, int]:
        tag = self.data[off]
        off += 1
        size_sel = tag & CT_SIZE_MASK
        if size_sel == CT_ABSOLUTE_WORD:
            return off + 2, int.from_bytes(self.data[off:off + 2], "big", signed=True) & 0xFFFFFFFF
        if size_sel == CT_ABSOLUTE_LONG:
            return off + 4, gl(self.data, off)
        if size_sel == CT_RELATIVE_START_WORD:
            rel = int.from_bytes(self.data[off:off + 2], "big", signed=True)
            return off + 2, (self.header.opcode_memory_addr + rel) & 0xFFFFFFFF
        raise ValueError(f"unexpected memory address size {size_sel:02x} at {off - 1:04x}")

    def apply_init_item(self, off: int) -> int:
        tag = self.data[off]
        mode = tag & CT_DATA_MASK
        if mode == CT_MEMWRITE:
            off, _addr = self.parse_mem_addr(off)
            off, _oldv, _size = self.restore_value(off, 0)
            off, _newv, _size = self.restore_value(off, 0)
            return off
        if mode == CT_MEMWRITES:
            off += 1
            lead = self.data[off]
            if lead == 0xFF:
                length = self.data[off + 2] or 256
                return off + 3 + length
            length = lead & 31 or 32
            return off + 1 + length
        if mode == CT_EDATA:
            return off + 3 if self.data[off + 1] == 1 else off + 2
        if tag == CT_OVERRIDE_REG:
            raise ValueError("override tag is not valid in init blocks")
        if mode < CT_AREG + 8 and (tag & CT_SIZE_MASK) == CT_SIZE_FPU:
            return self.parse_fpvalue(off)

        name = REG_NAMES.get(mode)
        if name is None:
            raise ValueError(f"unknown init mode {mode} at {off:04x}")
        if mode == CT_BRANCHTARGET:
            off, value, _size = self.restore_value(off, self.state.get(name, 0))
            self.state[name] = value
            self.state["BRANCHTARGET_MODE"] = self.data[off]
            return off + 1
        off, value, _size = self.restore_value(off, self.state.get(name, 0))
        self.state[name] = value
        return off

    def parse_override(self, off: int) -> Tuple[int, Tuple[str, int]]:
        if self.data[off] != CT_OVERRIDE_REG:
            raise ValueError(f"expected override at {off:04x}")
        regtag = self.data[off + 1]
        reg = regtag & CT_DATA_MASK
        name = REG_NAMES.get(reg, f"R{reg}")
        if (regtag & CT_SIZE_MASK) == CT_SIZE_FPU:
            return self.parse_fpvalue(off + 1), (name, 0)
        value = gl(self.data, off + 2)
        self.state[name] = value
        return off + 6, (name, value)

    def skip_exception_payload(self, off: int, exc: int) -> Tuple[int, int, bool, int]:
        if exc == 0:
            return off, 0, False, -1
        excdatalen = self.data[off]
        off += 1
        extra_trace = 0
        extra_trace_standalone = False
        group2_with_1 = -1
        if excdatalen not in (0, 0xFF) and excdatalen >= 1:
            extra = self.data[off]
            if extra & 0x40 and excdatalen >= 2:
                group2_with_1 = self.data[off + 1]
                extra &= ~0x40
            if (extra & 0x3F) == 9:
                extra_trace = 9
                extra_trace_standalone = bool(extra & 0x80)
        if excdatalen not in (0, 0xFF):
            off += excdatalen
        return off, extra_trace, extra_trace_standalone, group2_with_1

    def parse_expected_items(self, off: int) -> Tuple[int, List[MemWrite], int, int, bool, int, bool, int]:
        memwrites: List[MemWrite] = []
        while True:
            tag = self.data[off]
            if tag & CT_END:
                end_marker = tag
                off += 1
                exc = end_marker & CT_EXCEPTION_MASK
                off, extra_trace, extra_trace_standalone, group2_with_1 = self.skip_exception_payload(off, exc)
                return off, memwrites, end_marker, exc, bool(end_marker & 0x40), extra_trace, extra_trace_standalone, group2_with_1

            mode = tag & CT_DATA_MASK
            if mode == CT_MEMWRITE:
                off, addr = self.parse_mem_addr(off)
                off, oldv, size = self.restore_value(off, 0)
                off, newv, _size = self.restore_value(off, 0)
                memwrites.append(MemWrite(addr, size, oldv, newv))
                continue
            if mode == CT_MEMWRITES:
                off += 1
                lead = self.data[off]
                if lead == 0xFF:
                    length = self.data[off + 2] or 256
                    off += 3 + length
                else:
                    length = lead & 31 or 32
                    off += 1 + length
                continue
            if mode == CT_PC:
                off, _value = self.restore_rel(off, self.header.opcode_memory_addr)
                continue
            if mode == CT_BRANCHTARGET:
                off, _value = self.restore_rel(off, self.state.get("BRANCHTARGET", 0xFFFFFFFF))
                off += 1
                continue
            if mode == CT_EDATA:
                off += 3 if self.data[off + 1] == 1 else 2
                continue
            if mode < CT_AREG + 8 and (tag & CT_SIZE_MASK) == CT_SIZE_FPU:
                off = self.parse_fpvalue(off)
                continue
            off, _value, _size = self.restore_value(off, 0)

    def iter_subcases(self) -> Sequence[Tuple[Subcase, Dict[str, int]]]:
        out: List[Tuple[Subcase, Dict[str, int]]] = []
        off = 0
        record_index = 0
        while off < len(self.data):
            while self.data[off] not in (CT_END_INIT, CT_END_SKIP, CT_END_FINISH):
                off = self.apply_init_item(off)

            boundary = self.data[off]
            if boundary == CT_END_FINISH:
                break
            off += 1

            extraccr = 0
            group_index = 0
            while True:
                ccrmode = self.data[off]
                off += 1
                maxccr = ccrmode & 0x3F
                for ccrcnt in range(maxccr):
                    if self.header.interrupttest == 1:
                        off += 1

                    overrides: List[Tuple[str, int]] = []
                    while self.data[off] == CT_OVERRIDE_REG:
                        off, override = self.parse_override(off)
                        overrides.append(override)

                    if self.data[off] == CT_END_SKIP:
                        out.append(
                            (
                                Subcase(
                                    record_index=record_index,
                                    group_index=group_index,
                                    subcase_index=ccrcnt,
                                    extraccr=extraccr,
                                    ccrmode=ccrmode,
                                    ccr=ccrcnt & (maxccr - 1),
                                    overrides=overrides,
                                    end_marker=CT_END_SKIP,
                                ),
                                dict(self.state),
                            )
                        )
                        off += 1
                        continue

                    off, memwrites, end_marker, exc, branched, extra_trace, extra_trace_standalone, group2_with_1 = self.parse_expected_items(off)
                    out.append(
                        (
                            Subcase(
                                record_index=record_index,
                                group_index=group_index,
                                subcase_index=ccrcnt,
                                extraccr=extraccr,
                                ccrmode=ccrmode,
                                ccr=ccrcnt & (maxccr - 1),
                                overrides=overrides,
                                memwrites=memwrites,
                                end_marker=end_marker,
                                exc=exc,
                                branched=branched,
                                extra_trace=extra_trace,
                                extra_trace_standalone=extra_trace_standalone,
                                group2_with_1=group2_with_1,
                            ),
                            dict(self.state),
                        )
                    )

                if self.data[off] == CT_END:
                    off += 1
                    break
                extraccr = self.data[off]
                off += 1
                group_index += 1

            record_index += 1

        return out


def parse_header(header_path: Path) -> Header:
    data = header_path.read_bytes()
    off = 0
    if gl(data, off) not in DATA_VERSIONS:
        raise ValueError(f"unexpected data version in {header_path}")
    off += 4  # version
    off += 4  # starttimeid
    off += 4  # hmem/lmem
    test_memory_addr = gl(data, off)
    off += 4
    test_memory_size = gl(data, off)
    off += 4
    opcode_memory_addr = gl(data, off)
    off += 4
    flags = gl(data, off)
    off += 4
    interrupttest = (flags >> 26) & 3
    off += 4  # initial interrupt fields
    off += 4  # reserved
    off += 4  # reserved
    off += 4  # fpu model
    off += 4  # low start
    off += 4  # low end
    off += 4  # high start
    off += 4  # high end
    off += 4  # safe start
    off += 4  # safe end
    user_stack_memory = gl(data, off)
    off += 4
    super_stack_memory = gl(data, off)
    return Header(
        test_memory_addr=test_memory_addr,
        test_memory_size=test_memory_size,
        opcode_memory_addr=opcode_memory_addr,
        interrupttest=interrupttest,
        user_stack_memory=user_stack_memory,
        super_stack_memory=super_stack_memory,
    )


def fmt_hex(value: int, width: int = 8) -> str:
    return f"0x{value:0{width}X}"


def summarize_state(state: Dict[str, int]) -> str:
    parts = []
    for key in STATE_KEYS:
        if key in state:
            parts.append(f"{key}={fmt_hex(state[key])}")
    return " ".join(parts)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("case_file", type=Path, help="Packed testcase file, e.g. .../JMP/0002.dat.gz")
    ap.add_argument("--mem", type=lambda s: int(s, 0), nargs="*", default=[], help="Only show subcases with expected memwrites to these absolute addresses")
    ap.add_argument("--record", type=int, default=None, help="Only show a specific init-record index")
    ap.add_argument("--exc", type=int, default=None, help="Only show subcases with this expected exception number")
    ap.add_argument("--extra-trace", action="store_true", help="Only show subcases that encode an additional trace exception in the exception payload")
    ap.add_argument("--srcaddr", type=lambda s: int(s, 0), default=None, help="Only show subcases whose cumulative SRCADDR matches this value")
    ap.add_argument("--max-hits", type=int, default=20, help="Maximum matching subcases to print")
    args = ap.parse_args()

    header = parse_header(args.case_file.with_name("0000.dat"))
    payload = gzip.open(args.case_file, "rb").read()
    parser = Parser(header, payload)

    print(f"header: opcode_memory={fmt_hex(header.opcode_memory_addr)} test_memory={fmt_hex(header.test_memory_addr)} size={fmt_hex(header.test_memory_size)} interrupttest={header.interrupttest}")

    hits = 0
    for subcase, state in parser.iter_subcases():
        if args.record is not None and subcase.record_index != args.record:
            continue
        if args.exc is not None and subcase.exc != args.exc:
            continue
        if args.extra_trace and subcase.extra_trace != 9:
            continue
        if args.srcaddr is not None and state.get("SRCADDR") != args.srcaddr:
            continue
        if args.mem and not any(mw.addr in args.mem for mw in subcase.memwrites):
            continue
        hits += 1
        print(
            f"\nrecord={subcase.record_index} group={subcase.group_index} subcase={subcase.subcase_index} "
            f"ccrmode={subcase.ccrmode:#04x} ccr={subcase.ccr:#x} extraccr={subcase.extraccr:#04x} "
            f"end={subcase.end_marker:#04x} exc={subcase.exc} branched={int(subcase.branched)} "
            f"extra_trace={subcase.extra_trace} standalone={int(subcase.extra_trace_standalone)}"
        )
        print(f"state: {summarize_state(state)}")
        if subcase.overrides:
            print("overrides:")
            for name, value in subcase.overrides:
                print(f"  {name}={fmt_hex(value)}")
        if subcase.memwrites:
            print("expected memwrites:")
            for mw in subcase.memwrites:
                size_name = ("byte", "word", "long")[mw.size]
                print(
                    f"  {size_name} {fmt_hex(mw.addr)}: "
                    f"{fmt_hex(mw.old, (1, 2, 4)[mw.size] * 2)} -> {fmt_hex(mw.new, (1, 2, 4)[mw.size] * 2)}"
                )
        if hits >= args.max_hits:
            break

    if hits == 0:
        print("no matching subcases")


if __name__ == "__main__":
    main()
