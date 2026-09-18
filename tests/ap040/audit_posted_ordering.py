#!/usr/bin/env python3
"""Posted-write ordering: a regression gate for the two defects of 2026-09-18.

Both are fixed in production RTL now -- NOP waits for the store buffer
(M68040UM 7.7) and cache maintenance will not start over a pending store
(10.3) -- so this runs as a gate rather than a repro:

  posted        production RTL, production split enable .. must PASS
  unposted      POST_STORES=0 ......................... must PASS
  defect        the two fixes REMOVED ................. must FAIL, or the
                gate proves nothing
  defect_legacy the fixes removed AND the old shared
                bench enable .......................... must PASS, which is
                what hid the defects in the first place

The synthetic IRQ device is deliberately slow; this is a CPU ordering test,
not a simulation of either reported demo. Logs are authoritative: the
inherited bench exits zero even when its assembly program reports failure.
Exits non-zero if any expectation is violated.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
AP = ROOT / "rtl/ap040"


def replace_once(text, old, new):
    assert text.count(old) == 1, f"audit substitution no longer unique: {old}"
    return text.replace(old, new, 1)


def run(command, log):
    with log.open("w") as out:
        subprocess.run([str(x) for x in command], cwd=ROOT, stdout=out,
                       stderr=subprocess.STDOUT, check=True, timeout=300)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work", type=Path, default=Path("/tmp/ap040-posted-order-audit"))
    parser.add_argument("--jobs", type=int, default=4)
    args = parser.parse_args()
    work = args.work.resolve()
    work.mkdir(parents=True, exist_ok=True)
    bench = (HERE / "tb_ap040_program.v").read_text()
    # The bench now models the production split natively; the substitution
    # that used to create it here is gone.  Check it is really there --
    # without it every case below passes for the wrong reason.
    split = "wire        clkena_in = bus_clkena | post_drain;"
    assert split in bench, "tb_ap040_program no longer splits core and bus enables"
    for old, new in [(".cache_allow_all(1'b1)", ".cache_allow_all(1'b0)"),
                     (".cache_z3_base0(5'd0)", ".cache_z3_base0(5'd1)"),
                     (".cache_z3_ena0(1'b0)", ".cache_z3_ena0(1'b1)"),
                     ("if (addr_out[31:16] != 0) begin",
                      "if (addr_out[31:16] != 0 && addr_out[31:16] != 16'h0800 && addr_out != 32'h00dff110) begin")]:
        bench = replace_once(bench, old, new)
    bench = replace_once(bench, "reg [2:0] lat_cnt;", """
integer clear_delay = 0;
integer clear_wait = 200;
initial begin
 if ($value$plusargs("clear_wait=%d", clear_wait)) begin end
end
always @(posedge clk) begin
 if (!nreset || busstate != 2'b11 || addr_out != 32'h00dff110 || data_write != 0)
  clear_delay <= 0;
 else if (clear_delay < clear_wait) clear_delay <= clear_delay + 1;
 if (nreset && dut.core.state == 8'd34 && dut.core.exc_is_irq && !irq_seen_q)
  $display("AUDIT IRQ clear_pending=%b", dut.post_drain);
 if (nreset && dut.cinv_done && dut.post_drain) begin
  $display("FAIL: cache maintenance completed with a posted write pending");
  errors = errors + 1;
  result = 2;
 end
end
reg [2:0] lat_cnt;""")
    bench = replace_once(bench, "else if (phase == 2) begin", """
else if (busstate == 2'b11 && addr_out == 32'h00dff110 && data_write == 0 && clear_delay < clear_wait) begin
 mem_ready <= 0;
end
else if (phase == 2) begin""")
    bench_path = work / "tb_ap040_program.v"
    bench_path.write_text(bench)
    legacy_path = work / "tb_legacy_enable.v"
    legacy_path.write_text(replace_once(bench, split,
                                        "wire        clkena_in = bus_clkena;"))

    # The MUST-FAIL control: production RTL with both fixes taken back out.
    # If these cases pass, the gate is not testing what it claims to.
    core = (AP / "ap040_core.v").read_text()
    core = replace_once(core, """6'b110001: if (store_busy) state <= S_NOP_SYNC;
										           else fetch_next;   // NOP""",
                        "6'b110001: fetch_next;   // NOP (DEFECT CONTROL: sync removed)")
    defect_core = work / "ap040_core_defect.v"
    defect_core.write_text(core)
    cache = (AP / "ap040_cache.v").read_text()
    cache = replace_once(cache, """					if (!sb_v) begin
						sweep_cnt <= 0;
						sweep_all <= 0;   // honour the cinv_ic/cinv_dc selects
						cst <= C_SWEEP;
					end""", """					begin   // DEFECT CONTROL: interlock removed
						sweep_cnt <= 0;
						sweep_all <= 0;
						cst <= C_SWEEP;
					end""")
    defect_cache = work / "ap040_cache_defect.v"
    defect_cache.write_text(cache)

    program = (HERE / "asm/t_posted_irq_audit.s").read_text()
    images = {}
    for name, instruction in [("nop", "nop"), ("cinva", "cinva dc"), ("cpusha", "cpusha dc")]:
        asm = work / f"{name}.s"
        asm.write_text(replace_once(program, "\n nop\n", f"\n {instruction}\n"))
        binary = work / f"{name}.bin"
        run([os.environ.get("VASM", "/opt/amiga-cc/vbcc/bin/vasmm68k_mot"),
             "-quiet", "-Fbin", "-m68040", "-no-opt", "-o", binary, asm], work / f"{name}.assemble.log")
        data = binary.read_bytes()
        assert len(data) < 65536 and len(data) % 2 == 0
        images[name] = work / f"{name}.hex"
        images[name].write_text("".join(data[i:i+2].hex() + "\n" for i in range(0, len(data), 2)))

    results = []
    for config in ("posted", "unposted", "defect", "defect_legacy"):
        defective = config.startswith("defect")
        sources = [p for p in sorted(AP.glob("*.v"))
                   if not defective or p.name not in ("ap040_core.v", "ap040_cache.v")]
        if defective:
            sources += [defect_core, defect_cache]
        obj = work / ("obj-" + config)
        run(["verilator", "--binary", "--timing", "--top-module", "tb_ap040_program",
             "--Mdir", obj, "-j", args.jobs, "-Wno-fatal", "-I" + str(AP),
             "-GPOST_STORES=" + ("0" if config == "unposted" else "1"),
             legacy_path if config == "defect_legacy" else bench_path,
             HERE / "sim_dpram.v", *sources, ROOT / "rtl/memory_router.v"],
            work / f"{config}.compile.log")
        for name, image in images.items():
            for delay in (0, 32, 64, 128, 200):
                log = work / f"{config}-{name}-{delay}.log"
                run([obj / "Vtb_ap040_program", "+prog=" + str(image), f"+clear_wait={delay}"], log)
                output = log.read_text()
                passed = "ALL TESTS PASSED" in output and "FAIL:" not in output
                row = dict(config=config, instruction=name, delay=delay, passed=passed,
                           extra_irq="test 3 (phase" in output,
                           early_maintenance="cache maintenance completed with" in output)
                results.append(row)
                print(row, flush=True)
    (work / "results.json").write_text(json.dumps(results, indent=2) + "\n")

    # Expectations.  "defect" must fail for EVERY instruction: one that
    # always passed there would mean this gate cannot see its own defect.
    bad = []
    for config in ("posted", "unposted", "defect_legacy"):
        for row in [r for r in results if r["config"] == config and not r["passed"]]:
            bad.append(f"{config} {row['instruction']} delay {row['delay']}: FAILED, must pass")
    for instruction in ("nop", "cinva", "cpusha"):
        rows = [r for r in results if r["config"] == "defect" and r["instruction"] == instruction]
        if all(r["passed"] for r in rows):
            bad.append(f"defect {instruction}: every delay passed, so the gate "
                       f"does not detect the defect it exists for")
    for config in ("posted", "unposted", "defect", "defect_legacy"):
        rows = [r for r in results if r["config"] == config]
        print(f"{config:14s} {sum(r['passed'] for r in rows)}/{len(rows)} passed", flush=True)
    if bad:
        print("\nGATE FAILED:", flush=True)
        for line in bad:
            print("  " + line, flush=True)
        raise SystemExit(1)
    print("\nposted-ordering gate OK: production passes, the defect control still fails",
          flush=True)


if __name__ == "__main__":
    main()
