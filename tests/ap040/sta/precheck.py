# precheck.py -- reads the reports written by sta_precheck.tcl (same SPDIR) and
# prints the census comparison, the class table and PRECHECK PASS/FAIL.
import re,sys,os,collections
sp=sys.argv[1]
def names(f): return [l.strip() for l in open(f) if l.strip()]
allr=names(f"{sp}/pc_all.txt"); fr1=set(names(f"{sp}/pc_fr1.txt")); asyn=set(names(f"{sp}/pc_asyn.txt")); tick=set(names(f"{sp}/pc_tick.txt"))
def tos(rpt):
    s=set()
    for m in re.finditer(r"Slack\s*:\s*(-?[\d.]+)\nFrom Node\s*:\s*(\S+)\nTo Node\s*:\s*(\S+)",open(rpt).read()): s.add(re.sub(r"\|ena$","",m.group(3)))
    return s
ena=tos(f"{sp}/pc_ena.rpt"); anyr=tos(f"{sp}/pc_any.rpt")
def short(n):
    n=n.replace("emu:emu|cpu_wrapper:cpu_wrapper|ap040_tg68k_compat:cpu_inst_p|",""); n=re.sub(r"\[\d+\]","[]",n); n=re.sub(r"~DUPLICATE(_\d+)?|~_Duplicate_\d+","",n)
    return re.sub(r"altsyncram.*?~(port\w+?)_(\w+?)(\d*)$",r"~\1_\2",n)
fr=[r for r in allr if r not in anyr]
bad=[r for r in fr if r in tick]
ok=True
print(f"census: all={len(allr)} ena-from-core_phase={len([r for r in allr if r in ena])} free-running={len(fr)} | sets TICK={len(tick)} FR1={len(fr1)} ASYN={len(asyn)}")
if bad:
    ok=False; c=collections.Counter(short(r) for r in bad)
    print(f"FAIL: {len(bad)} free-running registers inside TICK:"); [print(f"   x{v:<4d} {k}") for k,v in sorted(c.items())]
else: print("OK: every free-running register is in FR1 or ASYN")
tg_in_asyn=[r for r in asyn|fr1 if r in ena]
if tg_in_asyn:
    c=collections.Counter(short(r) for r in tg_in_asyn); print(f"note: {len(tg_in_asyn)} ena-gated registers held single-cycle (conservative):"); [print(f"   x{v:<4d} {k}") for k,v in sorted(c.items())]
def paths(f):
    p=f"{sp}/{f}.rpt"
    if not os.path.exists(p): return None,[]
    txt=open(p).read(); m=re.search(r"Found (\d+) setup paths \((\d+) violated\)",txt)
    b=re.findall(r"Slack\s*:\s*(-?[\d.]+)\nFrom Node\s*:\s*(\S+)\nTo Node\s*:\s*(\S+).*?Relationship\s*:\s*([\d.]+)\nClock Skew\s*:\s*(-?[\d.]+)\nData Delay\s*:\s*([\d.]+)",txt,re.S)
    return (int(m.group(1)),int(m.group(2))) if m else (0,0), b
cnt,b=paths("pc_fr1_rdports")
if b: ok=False; print(f"FAIL: {cnt[0]} RAM-to-RAM chain paths outside the write ports, worst {b[0][0]}: {short(b[0][1])} -> {short(b[0][2])}")
else: print("OK: no FR1 -> RAM read-port chains")
def sh3(n): n=short(n); return "|".join(x.split(":")[-1] for x in n.split("|")[-3:])
print("class table (worst slack / relationship / data delay):")
for f in ["tick_tick","fr1_tick","tick_ctagb","fr1_ctagb","tick_atcb","fr1_atcb","fr1mmu_looks","tickcm_looks","tick_pipe","tick_rdports","asyn_tick","tick_asyn","asyn_asyn","ena_worst"]:
    cnt,b=paths("pc_"+f)
    if not b: print(f"   {f:14s} (no paths)"); continue
    s,fr_,to,r,k,d=b[0]; flag="  <-- NEGATIVE" if float(s)<0 else ""
    if float(s)<0: ok=False
    print(f"   {f:14s} {float(s):7.3f} rel {r:>6} data {float(d):6.3f}  {sh3(fr_)} -> {sh3(to)}{flag}")
cnt,b=paths("pc_c0_wide")
cl=collections.OrderedDict()
for s,fr_,to,r,k,d in b: cl.setdefault((sh3(fr_),sh3(to),r),[]).append(float(s))
print(f"worst-60 on clk_114, {len(cl)} classes:")
for (a,bb,r),v in sorted(cl.items(), key=lambda kv: min(kv[1]))[:8]: print(f"   {min(v):7.3f} x{len(v):<3d} rel {r}  {a} -> {bb}")
print("PRECHECK", "PASS" if ok else "FAIL")
