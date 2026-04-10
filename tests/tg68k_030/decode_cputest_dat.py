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
class BytePatch:
    addr: int
    data: bytes


@dataclass
class ExceptionSummary:
    frame_word: int | None = None
    pc: int | None = None
    instruction_addr: int | None = None
    second_addr: int | None = None


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
    init_memwrites: List[MemWrite] = field(default_factory=list)
    init_bytepatches: List[BytePatch] = field(default_factory=list)
    exception_payload_raw: bytes = b""
    trace_expected_sr: int | None = None
    trace_expected_pc: int | None = None
    exception_summary: ExceptionSummary | None = None
    expected_values: Dict[str, int] = field(default_factory=dict)
    expected_sr_ignore_mask: int | None = None


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
        self.current_init_memwrites: List[MemWrite] = []
        self.current_init_bytepatches: List[BytePatch] = []

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

    def parse_memwrite(self, off: int) -> Tuple[int, MemWrite]:
        off, addr = self.parse_mem_addr(off)
        off, oldv, size = self.restore_value(off, 0)
        off, newv, _size = self.restore_value(off, 0)
        return off, MemWrite(addr, size, oldv, newv)

    def parse_memwrites_block(self, off: int) -> Tuple[int, BytePatch]:
        tag = self.data[off]
        off += 1
        size_sel = tag & CT_SIZE_MASK
        if size_sel != CT_PC_BYTES:
            raise ValueError(f"unexpected CT_MEMWRITES size {size_sel:02x} at {off - 1:04x}")

        if self.data[off] == 0xFF:
            offset = self.data[off + 1]
            length = self.data[off + 2] or 256
            data = bytes(self.data[off + 3:off + 3 + length])
            off += 3 + length
        else:
            lead = self.data[off]
            offset = lead >> 5
            length = lead & 31 or 32
            data = bytes(self.data[off + 1:off + 1 + length])
            off += 1 + length

        return off, BytePatch(self.header.opcode_memory_addr + offset, data)

    def apply_init_item(self, off: int) -> int:
        tag = self.data[off]
        mode = tag & CT_DATA_MASK
        if mode == CT_MEMWRITE:
            off, memwrite = self.parse_memwrite(off)
            self.current_init_memwrites.append(memwrite)
            return off
        if mode == CT_MEMWRITES:
            off, bytepatch = self.parse_memwrites_block(off)
            self.current_init_bytepatches.append(bytepatch)
            return off
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

    def skip_exception_payload(self, off: int, exc: int) -> Tuple[int, bytes, int, bool, int]:
        if exc == 0:
            return off, b"", 0, False, -1
        excdatalen = self.data[off]
        if excdatalen == 0xFF:
            payload_raw = bytes(self.data[off:off + 1])
        else:
            payload_raw = bytes(self.data[off:off + 1 + excdatalen])
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
        return off, payload_raw, extra_trace, extra_trace_standalone, group2_with_1

    def decode_exception_payload(
        self, payload_raw: bytes, exc: int
    ) -> Tuple[int | None, int | None, ExceptionSummary | None]:
        if exc == 0 or not payload_raw:
            return None, None, None

        excdatalen = payload_raw[0]
        if excdatalen == 0 or excdatalen == 0xFF:
            return None, None, None

        pos = 1
        payload_end = 1 + excdatalen
        trace_expected_sr = None
        trace_expected_pc = None
        exception_summary = None

        extra = payload_raw[pos]
        pos += 1
        if extra & 0x40 and pos < payload_end:
            pos += 1
            extra &= ~0x40

        if (extra & 0x3F) == 9 and (extra & 0x80):
            if pos + 2 <= payload_end:
                trace_expected_sr = int.from_bytes(payload_raw[pos:pos + 2], "big")
                pos += 2
            if pos < payload_end:
                pos, trace_expected_pc = self.decode_rel_from_bytes(payload_raw, pos, self.header.opcode_memory_addr)

        if exc != 1 and pos < payload_end:
            summary = ExceptionSummary()
            pos, summary.pc = self.decode_rel_from_bytes(payload_raw, pos, self.header.opcode_memory_addr)
            if pos + 2 <= payload_end:
                summary.frame_word = int.from_bytes(payload_raw[pos:pos + 2], "big")
                pos += 2
                frame_fmt = summary.frame_word >> 12
                if frame_fmt in (2, 3) and pos < payload_end:
                    pos, summary.instruction_addr = self.decode_rel_from_bytes(payload_raw, pos, self.header.opcode_memory_addr)
                elif frame_fmt == 4 and pos < payload_end:
                    pos, summary.instruction_addr = self.decode_rel_from_bytes(payload_raw, pos, self.header.opcode_memory_addr)
                    if pos < payload_end:
                        pos, summary.second_addr = self.decode_rel_from_bytes(payload_raw, pos, self.header.opcode_memory_addr)
            exception_summary = summary

        return trace_expected_sr, trace_expected_pc, exception_summary

    @staticmethod
    def decode_rel_from_bytes(buf: bytes, off: int, cur: int = 0) -> Tuple[int, int]:
        tag = buf[off]
        off += 1
        size_sel = tag & CT_SIZE_MASK
        if size_sel == CT_RELATIVE_START_BYTE:
            delta = int.from_bytes(buf[off:off + 1], "big", signed=True)
            return off + 1, (cur + delta) & 0xFFFFFFFF
        if size_sel == CT_RELATIVE_START_WORD:
            delta = int.from_bytes(buf[off:off + 2], "big", signed=True)
            return off + 2, (cur + delta) & 0xFFFFFFFF
        if size_sel == CT_ABSOLUTE_WORD:
            return off + 2, int.from_bytes(buf[off:off + 2], "big", signed=True) & 0xFFFFFFFF
        if size_sel == CT_ABSOLUTE_LONG:
            return off + 4, int.from_bytes(buf[off:off + 4], "big")
        raise ValueError(f"unexpected decode_rel size {size_sel:02x} at {off - 1:04x}")

    def parse_expected_items(
        self, off: int, expected_state: Dict[str, int]
    ) -> Tuple[
        int,
        List[MemWrite],
        Dict[str, int],
        int | None,
        int,
        int,
        bool,
        int,
        bool,
        int,
        bytes,
    ]:
        memwrites: List[MemWrite] = []
        expected_values: Dict[str, int] = {}
        expected_sr_ignore_mask: int | None = None
        cur_state = dict(expected_state)
        while True:
            tag = self.data[off]
            if tag & CT_END:
                end_marker = tag
                exc = end_marker & CT_EXCEPTION_MASK
                off, payload_raw, extra_trace, extra_trace_standalone, group2_with_1 = self.skip_exception_payload(off + 1, exc)
                return (
                    off,
                    memwrites,
                    expected_values,
                    expected_sr_ignore_mask,
                    end_marker,
                    exc,
                    bool(end_marker & 0x40),
                    extra_trace,
                    extra_trace_standalone,
                    group2_with_1,
                    payload_raw,
                )

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
                cur_pc = cur_state.get("PC", self.header.opcode_memory_addr)
                off, value = self.restore_rel(off, cur_pc)
                cur_state["PC"] = value
                expected_values["PC"] = value
                continue
            if mode == CT_BRANCHTARGET:
                cur_bt = cur_state.get("BRANCHTARGET", 0xFFFFFFFF)
                off, value = self.restore_rel(off, cur_bt)
                cur_state["BRANCHTARGET"] = value
                expected_values["BRANCHTARGET"] = value
                off += 1
                continue
            if mode == CT_SRCADDR:
                cur_src = cur_state.get("SRCADDR", 0)
                off, value = self.restore_rel(off, cur_src)
                cur_state["SRCADDR"] = value
                expected_values["SRCADDR"] = value
                continue
            if mode == CT_DSTADDR:
                cur_dst = cur_state.get("DSTADDR", 0)
                off, value = self.restore_rel(off, cur_dst)
                cur_state["DSTADDR"] = value
                expected_values["DSTADDR"] = value
                continue
            if mode == CT_EDATA:
                off += 3 if self.data[off + 1] == 1 else 2
                continue
            if mode < CT_AREG + 8 and (tag & CT_SIZE_MASK) == CT_SIZE_FPU:
                off = self.parse_fpvalue(off)
                continue
            name = REG_NAMES.get(mode)
            cur_value = cur_state.get(name, 0) if name is not None else 0
            off, value, _size = self.restore_value(off, cur_value)
            if name is None:
                continue
            cur_state[name] = value
            expected_values[name] = value
            if mode == CT_SR:
                expected_sr_ignore_mask = (~(value >> 16)) & 0xFFFF

    def iter_subcases(self) -> Sequence[Tuple[Subcase, Dict[str, int]]]:
        out: List[Tuple[Subcase, Dict[str, int]]] = []
        off = 0
        record_index = 0
        while off < len(self.data):
            self.current_init_memwrites = []
            self.current_init_bytepatches = []
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
                                    init_memwrites=list(self.current_init_memwrites),
                                    init_bytepatches=list(self.current_init_bytepatches),
                                ),
                                dict(self.state),
                            )
                        )
                        off += 1
                        continue

                    (
                        off,
                        memwrites,
                        expected_values,
                        expected_sr_ignore_mask,
                        end_marker,
                        exc,
                        branched,
                        extra_trace,
                        extra_trace_standalone,
                        group2_with_1,
                        exception_payload_raw,
                    ) = self.parse_expected_items(off, self.state)
                    trace_expected_sr, trace_expected_pc, exception_summary = self.decode_exception_payload(exception_payload_raw, exc)
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
                                init_memwrites=list(self.current_init_memwrites),
                                init_bytepatches=list(self.current_init_bytepatches),
                                exception_payload_raw=exception_payload_raw,
                                trace_expected_sr=trace_expected_sr,
                                trace_expected_pc=trace_expected_pc,
                                exception_summary=exception_summary,
                                expected_values=expected_values,
                                expected_sr_ignore_mask=expected_sr_ignore_mask,
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


def sr_mask_from_extraccr(extraccr: int) -> int:
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


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("case_file", type=Path, help="Packed testcase file, e.g. .../JMP/0002.dat.gz")
    ap.add_argument("--mem", type=lambda s: int(s, 0), nargs="*", default=[], help="Only show subcases with expected memwrites to these absolute addresses")
    ap.add_argument("--record", type=int, default=None, help="Only show a specific init-record index")
    ap.add_argument("--exc", type=int, default=None, help="Only show subcases with this expected exception number")
    ap.add_argument("--extra-trace", action="store_true", help="Only show subcases that encode an additional trace exception in the exception payload")
    ap.add_argument("--srcaddr", type=lambda s: int(s, 0), default=None, help="Only show subcases whose cumulative SRCADDR matches this value")
    ap.add_argument("--show-init", action="store_true", help="Show init-record memory patches that build the matched subcase")
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
        if subcase.extraccr:
            effective_sr = state.get("SR", 0) | sr_mask_from_extraccr(subcase.extraccr)
            print(f"effective SR high bits from extraccr: {fmt_hex(effective_sr, 4)}")
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
        if args.show_init:
            if subcase.init_memwrites:
                print("init memwrites:")
                for mw in subcase.init_memwrites:
                    size_name = ("byte", "word", "long")[mw.size]
                    print(
                        f"  {size_name} {fmt_hex(mw.addr)}: "
                        f"{fmt_hex(mw.old, (1, 2, 4)[mw.size] * 2)} -> {fmt_hex(mw.new, (1, 2, 4)[mw.size] * 2)}"
                    )
            if subcase.init_bytepatches:
                print("init bytepatches:")
                for patch in subcase.init_bytepatches:
                    print(f"  {fmt_hex(patch.addr)}: {' '.join(f'{b:02X}' for b in patch.data)}")
        if hits >= args.max_hits:
            break

    if hits == 0:
        print("no matching subcases")


if __name__ == "__main__":
    main()
