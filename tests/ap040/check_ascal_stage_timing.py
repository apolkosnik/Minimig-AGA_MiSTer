#!/usr/bin/env python3
"""Compare the actual retimed scaler stages with their frozen original RTL.

Checks all observed fraction stages (2..9) and vertical pixel tuples cycle
for cycle, with geometry changes, line boundaries and pixel-enable gaps.
"""
import argparse
from pathlib import Path
import re
import subprocess

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work", type=Path, required=True)
    args = parser.parse_args()
    work = args.work.resolve()
    work.mkdir(parents=True, exist_ok=True)
    source = (ROOT / "sys/ascal.vhd").read_text()
    types = [re.search(r"TYPE type_pix IS RECORD.*?END RECORD;", source, re.S)[0]]
    for name in ("arr_pix", "arr_frac", "arr_div"):
        types.append(re.search(rf"TYPE {name} IS ARRAY.*?;", source)[0])
    start = source.index("-- Pipelined 8 bits non-restoring divider. Cycle 1",
                         source.index("HSCAL:PROCESS"))
    horizontal = source[start:source.index("o_copyv(1 TO 14)", start)]
    start = source.index("-- CYCLE 8", source.index("VSCAL:PROCESS"))
    vertical = source[start:source.index("-- BILINEAR / SHARP BILINEAR", start)]
    reference_h = (HERE / "ref/ascal_horizontal_before.vhd.inc").read_text()
    reference_v = (HERE / "ref/ascal_vertical_before.vhd.inc").read_text()
    text = """library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
entity tb_ascal_stage_timing is
  generic (FRAC : natural := 8);
end;
architecture test of tb_ascal_stage_timing is
""" + "\n".join(types) + """
  signal o_clk : std_logic := '0';
  signal o_ce, fracnn : std_logic := '0';
  signal o_hacc : natural range 0 to 8191 := 0;
  signal o_hsize,o_ivsize : natural range 0 to 4095 := 0;
  signal o_vacpt : unsigned(11 downto 0) := (others=>'0');
  signal o_vpix_outer : arr_pix(0 to 2) := (others=>(others=>(others=>'0')));
  signal o_vpix_inner : arr_pix(0 to 6) := (others=>(others=>(others=>'0')));
  signal candidate_frac, reference_frac : arr_frac(0 to 9);
  signal candidate_pix, reference_pix : arr_pix(0 to 3);
begin
  o_clk <= not o_clk after 5 ns;
"""
    for name, hblock, vblock in (("candidate", horizontal, vertical),
                                 ("reference", reference_h, reference_v)):
        text += f"{name}: block\n" + """
      signal o_div : arr_div(0 to 2);
      signal o_dir : arr_frac(0 to 2);
      signal o_hfrac : arr_frac(0 to 9);
      signal o_hdiv_last : unsigned(20 downto 0);
      signal o_hdiv_last_size : unsigned(11 downto 0);
      signal o_vpixq_pre,o_vpixq : arr_pix(0 to 3);
      signal o_vpix_past_end,o_vpix_at_end : boolean;
      signal o_vpix_fracnn : std_logic;
    begin
      process(o_clk)
        variable div_v : unsigned(20 downto 0);
        variable dir_v : unsigned(11 downto 0);
        variable fracnn_v : std_logic;
      begin
        if rising_edge(o_clk) then
""" + hblock + """
          if o_ce='1' then
            fracnn_v := fracnn;
""" + vblock + """
          end if;
        end if;
      end process;
""" + f"{name}_frac <= o_hfrac;\n{name}_pix <= o_vpixq;\nend block;\n"
    text += """
  process
    variable seed : unsigned(31 downto 0) := x"BE273149";
    procedure advance is
    begin
      seed := seed xor shift_left(seed,13);
      seed := seed xor shift_right(seed,17);
      seed := seed xor shift_left(seed,5);
    end;
    function pixel(s : unsigned(31 downto 0)) return type_pix is
    begin
      return (s(7 downto 0),s(15 downto 8),s(23 downto 16));
    end;
  begin
    for n in 0 to 19999 loop
      wait until falling_edge(o_clk);
      advance;
      o_hacc <= to_integer(seed(12 downto 0));
      -- Every divisor, including zero; changing it each cycle checks the
      -- retained divisor at the new pipeline boundary.
      o_hsize <= n mod 4096;
      o_vacpt <= seed(23 downto 12);
      case n mod 4 is
        when 0 => o_ivsize <= to_integer(seed(23 downto 12));
        when 1 => o_ivsize <= (to_integer(seed(23 downto 12))+1) mod 4096;
        when 2 => o_ivsize <= (to_integer(seed(23 downto 12))+4095) mod 4096;
        when others => o_ivsize <= to_integer(seed(11 downto 0));
      end case;
      fracnn <= seed(31);
      o_ce <= '1';
      if n mod 7=0 or n mod 13<3 then o_ce <= '0'; end if;
      for i in 0 to 2 loop advance; o_vpix_outer(i) <= pixel(seed); end loop;
      for i in 0 to 6 loop advance; o_vpix_inner(i) <= pixel(seed); end loop;
      wait until rising_edge(o_clk);
      wait for 1 ns;
      if n>20 then
        assert candidate_frac(2 to 9)=reference_frac(2 to 9)
          report "horizontal fraction/latency mismatch at cycle " & integer'image(n) severity failure;
        assert candidate_pix=reference_pix
          report "vertical pixel/latency mismatch at cycle " & integer'image(n) severity failure;
      end if;
    end loop;
    report "PASS: 20000 fraction/edge pipeline cycles, FRAC=" & integer'image(FRAC);
    std.env.stop;
    wait;
  end process;
end;
"""
    bench = work / "tb_ascal_stage_timing.vhd"
    bench.write_text(text)
    for command in (["ghdl", "-a", "--std=08", str(bench)],
                    ["ghdl", "-e", "--std=08", "tb_ascal_stage_timing"]):
        subprocess.run(command, cwd=work, check=True, timeout=60)
    for frac in (4, 5, 6, 7, 8):
        subprocess.run(["ghdl", "-r", "--std=08", "tb_ascal_stage_timing",
                        f"-gFRAC={frac}", "--assert-level=error",
                        "--ieee-asserts=disable-at-0"],
                       cwd=work, check=True, timeout=120)


if __name__ == "__main__":
    main()
