#!/usr/bin/env python3
import ast
import operator
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HPS_ABI = ROOT / "extra" / "minimig_eth_abi.h"
RTL = ROOT / "rtl" / "ethernet.v"

CHECKS = [
    ("ETH_CTRL_FLAGS", "ETH_SHM_CTRL_FLAGS"),
    ("ETH_CTRL_REGS", "ETH_SHM_CTRL_REGS"),
    ("ETH_CTRL_MAC", "ETH_SHM_CTRL_MAC"),
    ("ETH_CTRL_STATUS", "ETH_SHM_CTRL_STATUS"),
    ("ETH_HPS_HEARTBEAT", "ETH_SHM_HPS_HEARTBEAT"),
    ("ETH_HPS_SIGNATURE", "ETH_SHM_HPS_SIGNATURE"),
    ("ETH_PACKET_BUFFER_SIZE", "ETH_PACKET_BUFFER_SIZE"),
    ("ETH_TX_BUFFER", "ETH_SHM_TX_BUFFER"),
    ("ETH_RX_BUFFER", "ETH_SHM_RX_BUFFER"),
    ("ETH_PACKET_INFO", "ETH_SHM_PACKET_INFO"),
    ("ETH_TX_REQUEST_ADDR", "ETH_SHM_TX_REQUEST_ADDR"),
    ("ETH_TX_REQUEST_LEN", "ETH_SHM_TX_REQUEST_LEN"),
    ("ETH_RX_QUEUE_HEAD", "ETH_SHM_RX_QUEUE_HEAD"),
    ("ETH_RX_QUEUE_TAIL", "ETH_SHM_RX_QUEUE_TAIL"),
    ("ETH_TX_REQUEST_SEQ", "ETH_SHM_TX_REQUEST_SEQ"),
    ("ETH_TX_COMPLETE_SEQ", "ETH_SHM_TX_COMPLETE_SEQ"),
    ("ETH_RX_QUEUE_LEN", "ETH_SHM_RX_QUEUE_LEN"),
    ("ETH_RX_QUEUE_DATA", "ETH_SHM_RX_QUEUE_DATA"),
    ("ETH_RX_QUEUE_SLOTS", "ETH_RX_QUEUE_SLOTS"),
    ("ETH_FLAG_TX_REQ", "ETH_FLAG_TX_REQ"),
    ("ETH_FLAG_RX_AVAIL", "ETH_FLAG_RX_AVAIL"),
    ("ETH_FLAG_IRQ", "ETH_FLAG_IRQ"),
    ("ETH_FLAG_ENABLED", "ETH_FLAG_ENABLED"),
    ("ETH_FLAG_FPGA_MIRROR_MASK", "ETH_FPGA_FLAG_MASK"),
    ("ETH_STATUS_FPGA_SAMPLED", "ETH_STATUS_FPGA_SAMPLED"),
    ("ETH_STATUS_FPGA_SIGNATURE", "ETH_STATUS_FPGA_SIGNATURE"),
    ("ETH_STATUS_FPGA_HEARTBEAT", "ETH_STATUS_FPGA_HEARTBEAT"),
    ("ETH_STATUS_FPGA_HB_CHANGED", "ETH_STATUS_FPGA_HB_CHANGED"),
    ("ETH_STATUS_FPGA_COMM_OK", "ETH_STATUS_FPGA_COMM_OK"),
    ("ETH_STATUS_FPGA_RX_ACTIVE", "ETH_STATUS_FPGA_RX_ACTIVE"),
    ("ETH_STATUS_FPGA_TX_PENDING", "ETH_STATUS_FPGA_TX_PENDING"),
]

OPS = {
    ast.BitOr: operator.or_,
    ast.BitAnd: operator.and_,
    ast.Add: operator.add,
    ast.Sub: operator.sub,
    ast.LShift: operator.lshift,
    ast.RShift: operator.rshift,
}


def normalize_expr(expr):
    expr = expr.strip()
    expr = re.sub(r"/\*.*?\*/", "", expr)
    expr = expr.split("//", 1)[0].strip()
    expr = re.sub(r"\b\d+'h([0-9a-fA-F_xXzZ]+)", lambda m: "0x" + clean_digits(m.group(1)), expr)
    expr = re.sub(r"\b\d+'d([0-9_]+)", lambda m: clean_digits(m.group(1)), expr)
    return expr


def clean_digits(value):
    return value.replace("_", "").replace("x", "0").replace("X", "0").replace("z", "0").replace("Z", "0")


def read_hps_defs():
    defs = {}
    for line in HPS_ABI.read_text().splitlines():
        match = re.match(r"\s*#define\s+([A-Za-z_][A-Za-z0-9_]*)\s+(.+)$", line)
        if match:
            defs[match.group(1)] = normalize_expr(match.group(2))
    return defs


def read_rtl_defs():
    defs = {}
    pattern = re.compile(
        r"\b(?:localparam|parameter)\s*(?:\[[^\]]+\])?\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*([^;]+);"
    )
    for match in pattern.finditer(RTL.read_text()):
        defs[match.group(1)] = normalize_expr(match.group(2))
    return defs


def eval_expr(name, defs, cache):
    if name in cache:
        return cache[name]
    if name not in defs:
        raise KeyError(name)
    value = eval_ast(ast.parse(defs[name], mode="eval").body, defs, cache)
    cache[name] = value
    return value


def eval_ast(node, defs, cache):
    if isinstance(node, ast.Constant) and isinstance(node.value, int):
        return node.value
    if isinstance(node, ast.Name):
        return eval_expr(node.id, defs, cache)
    if isinstance(node, ast.BinOp) and type(node.op) in OPS:
        return OPS[type(node.op)](eval_ast(node.left, defs, cache), eval_ast(node.right, defs, cache))
    if isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.USub):
        return -eval_ast(node.operand, defs, cache)
    raise ValueError(f"unsupported expression: {ast.dump(node)}")


def main():
    hps_defs = read_hps_defs()
    rtl_defs = read_rtl_defs()
    hps_cache = {}
    rtl_cache = {}
    failed = False

    for hps_name, rtl_name in CHECKS:
        try:
            hps_value = eval_expr(hps_name, hps_defs, hps_cache)
            rtl_value = eval_expr(rtl_name, rtl_defs, rtl_cache)
        except Exception as exc:
            print(f"FAIL: {hps_name}/{rtl_name}: {exc}")
            failed = True
            continue

        if hps_value != rtl_value:
            print(f"FAIL: {hps_name}={hps_value:#06x} but {rtl_name}={rtl_value:#06x}")
            failed = True

    queue_end = (
        eval_expr("ETH_RX_QUEUE_DATA", hps_defs, hps_cache)
        + eval_expr("ETH_RX_QUEUE_SLOTS", hps_defs, hps_cache)
        * eval_expr("ETH_PACKET_BUFFER_SIZE", hps_defs, hps_cache)
    )
    if queue_end > 0x10000:
        print(f"FAIL: RX queue ends outside shared window at {queue_end:#06x}")
        failed = True

    if failed:
        raise SystemExit(1)

    print(f"PASS: ethernet ABI constants match ({len(CHECKS)} checks)")


if __name__ == "__main__":
    main()
