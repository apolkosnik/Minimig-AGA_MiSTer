#!/usr/bin/env python3
"""Check the scaler's production arithmetic and retimed pixel pipelines.

Uses the actual VHDL functions from sys/ascal.vhd. Covers every 19-bit sum
with varying signed partial sums, discarded low bits, saturation boundaries,
and clock-enable gaps; also exhausts RGB luminance and video-counter inputs,
and checks modular horizontal accumulator feedback over varied geometry.
This is a datapath check, not a full video simulation.
"""
import argparse
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work", type=Path, required=True)
    args = parser.parse_args()
    args.work.mkdir(parents=True, exist_ok=True)
    source = (ROOT / "sys/ascal.vhd").read_text()
    declarations = []
    for name in ("type_pix", "type_poly_t", "type_poly_sum"):
        declarations.append(re.search(
            rf"\bTYPE {name} IS RECORD.*?END RECORD;", source, re.S | re.I)[0])
    for name in ("to_std_logic", "bound", "poly_sum", "poly_bound",
                 "poly_lum_pair", "poly_lum_finish", "last_pos"):
        declarations.append(re.search(
            rf"\bFUNCTION {name}\s*\(.*?END FUNCTION(?: {name})?;",
            source, re.S | re.I)[0])
    step = re.search(r"hstep_v:=(.*?);", source)[1]
    advance = re.search(r"o_hacc_next<=\((o_hacc_next \+ hstep_v).*?;", source)[0]
    advance = advance.split("<=", 1)[1].rstrip(";")
    declarations.append(f"""
    function hacc_feedback(o_hacc_next,o_ihsize,o_hsize,OHRESH : natural) return natural is
      variable hstep_v : natural;
    begin
      hstep_v := {step};
      return {advance};
    end;
    """)
    bench = '''library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
entity tb_ascal_poly_timing is end;
architecture test of tb_ascal_poly_timing is
''' + "\n".join(declarations) + '''
  signal clk : std_logic := '0';
  signal ce : std_logic := '0';
  signal t : type_poly_t := (others => (others => '0'));
  signal sums, held_sums : type_poly_sum := (others => (others => '0'));
  signal reference, held_reference : type_pix := (others => (others => '0'));
  signal actual_out, expected_out, held_out, held_expected : type_pix := (others => (others => '0'));
  signal lum_pix : type_pix := (others => (others => '0'));
  signal lum_pair : unsigned(15 downto 0) := (others => '0');
  signal lum_reference, lum_actual, lum_expected : unsigned(7 downto 0) := (others => '0');

  -- Integer model of the original fixed-point operation: truncate each
  -- partial product, add modulo 19 bits, then clamp to an unsigned pixel.
  function channel(a,b : signed(26 downto 0)) return unsigned is
    variable total : integer;
  begin
    total := (to_integer(a(26 downto 8)) + to_integer(b(26 downto 8))) mod 524288;
    if total >= 262144 then return x"00";
    elsif total >= 32768 then return x"FF";
    else return to_unsigned(total / 128, 8);
    end if;
  end;
  function reference_pixel(v : type_poly_t) return type_pix is
  begin
    return (channel(v.r0,v.r1), channel(v.g0,v.g1), channel(v.b0,v.b1));
  end;
  function reference_lum(v : type_pix) return unsigned is
    variable m : natural;
  begin
    m := to_integer(v.r);
    if to_integer(v.g) > m then m := to_integer(v.g); end if;
    if to_integer(v.b) > m then m := to_integer(v.b); end if;
    return to_unsigned(m,8);
  end;
begin
  clk <= not clk after 5 ns;
  process(clk) begin
    if rising_edge(clk) then
      -- Horizontal path runs every clock. Vertical path has o_ce gaps.
      sums <= poly_sum(t);
      reference <= reference_pixel(t);
      actual_out <= poly_bound(sums);
      expected_out <= reference;
      if ce = '1' then
        held_sums <= poly_sum(t);
        held_reference <= reference_pixel(t);
        held_out <= poly_bound(held_sums);
        held_expected <= held_reference;
        -- C3 retains its value with adaptive sampling disabled; C4 runs
        -- every clock, just as in the production coefficient pipeline.
        lum_pair <= poly_lum_pair(lum_pix);
        lum_reference <= reference_lum(lum_pix);
      end if;
      lum_actual <= poly_lum_finish(lum_pair);
      lum_expected <= lum_reference;
    end if;
  end process;
  process
    variable seed : unsigned(31 downto 0) := x"739AC581";
    variable v : type_poly_t;
    variable pix : type_pix;
    variable a,b : natural;
    variable expected_max : natural;
    type sizes_t is array(natural range <>) of natural;
    constant sizes : sizes_t := (0,1,2,320,640,720,1080,1920,4095);
    procedure pair(sum_value : natural; variable x,y : out signed(26 downto 0)) is
    begin
      seed := seed xor shift_left(seed,13);
      seed := seed xor shift_right(seed,17);
      seed := seed xor shift_left(seed,5);
      a := to_integer(seed(18 downto 0));
      b := (sum_value + 524288 - a) mod 524288;
      x := signed(to_unsigned(a,19) & seed(26 downto 19));
      y := signed(to_unsigned(b,19) & not seed(26 downto 19));
    end;
  begin
    for i in 0 to 524287 loop
      wait until falling_edge(clk);
      pair(i, v.r0, v.r1);
      pair((i + 32767) mod 524288, v.g0, v.g1);
      pair((524287 - i), v.b0, v.b1);
      t <= v;
      lum_pix <= (seed(7 downto 0), seed(15 downto 8), seed(23 downto 16));
      ce <= seed(31) or seed(30);
      wait until rising_edge(clk);
      wait for 1 ns;
      assert actual_out = expected_out report "continuous pixel/latency mismatch" severity failure;
      assert held_out = held_expected report "enabled pixel/latency mismatch" severity failure;
      assert lum_actual = lum_expected report "luminance pixel/latency mismatch" severity failure;
    end loop;
    -- Drain the last sample through both stages.
    ce <= '1';
    for i in 0 to 2 loop
      wait until rising_edge(clk);
      wait for 1 ns;
      assert actual_out = expected_out and held_out = held_expected severity failure;
    end loop;
    report "PASS: all 524288 sums, three channels, continuous and stalled pipelines";
    for r in 0 to 255 loop
      for g in 0 to 255 loop
        for b in 0 to 255 loop
          pix := (to_unsigned(r,8), to_unsigned(g,8), to_unsigned(b,8));
          expected_max := r;
          if g > expected_max then expected_max := g; end if;
          if b > expected_max then expected_max := b; end if;
          assert to_integer(poly_lum_finish(poly_lum_pair(pix))) = expected_max
            report "luminance maximum mismatch" severity failure;
        end loop;
      end loop;
    end loop;
    report "PASS: all 16777216 RGB luminance inputs";
    for pos in 0 to 4095 loop
      for total in 0 to 4095 loop
        assert last_pos(pos,total) = (pos+1 >= total)
          report "video counter boundary mismatch" severity failure;
      end loop;
    end loop;
    report "PASS: all 16777216 video counter/total combinations";
    for a in 0 to 16383 loop
      for i in sizes'range loop
        for o in sizes'range loop
          assert hacc_feedback(a,sizes(i),sizes(o),4096) =
                 (a-2*sizes(o)+2*sizes(i)) mod 16384
            report "horizontal accumulator feedback mismatch" severity failure;
        end loop;
      end loop;
    end loop;
    report "PASS: 1327104 horizontal accumulator/geometry combinations";
    std.env.stop;
    wait;
  end process;
end;
'''
    path = args.work.resolve() / "tb_ascal_poly_timing.vhd"
    path.write_text(bench)
    for command in (
        ["ghdl", "-a", "--std=08", str(path)],
        ["ghdl", "-e", "--std=08", "tb_ascal_poly_timing"],
        ["ghdl", "-r", "--std=08", "tb_ascal_poly_timing", "--assert-level=error"],
    ):
        subprocess.run(command, cwd=args.work, check=True, timeout=900)


if __name__ == "__main__":
    main()
