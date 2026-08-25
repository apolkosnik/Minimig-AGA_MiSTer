# WinUAE cputest, 68040 corpus (DATA_VERSION 24): two generator defects

Report prepared 2026-08-20 against the `data040` corpus and WinUAE master as
pulled 2026-08-19.  Both defects are in the **generator** (`cputest.cpp`),
not in the runtime, and both produce recorded rounds that no real MC68040 can
satisfy.  Every finding below is derived from the shipped corpus bytes plus
the WinUAE sources; nothing depends on the implementation that found them.

Context: these are the only 25 of 3,801 corpus slices that a from-scratch
FPGA MC68040 core fails after all its own bugs were fixed.  The other 3,776
pass, including every slice in Basic, IRQ, AE, ODD_STK, Default, FPACK,
EXTSRC, EXTDST and FINT.

---

## Issue 1: the memory-source operand is planted at an address that is not the instruction's effective address

### Symptom

For a handful of FPU tests with a memory source operand, the generator writes
the intended operand to address X, but the instruction it recorded computes
effective address Y != X.  The generator's own emulated execution reads Y,
finds whatever its persistent memory image happens to hold there, and records
*that* as the expected result.  A real CPU reads Y too, but Y holds the
pristine `tmem.dat` contents, because the runtime reverts every test's memory
writes (`restoreahist`, `cputest/main.c:3590`).  The expectation is therefore
unreachable.

### Evidence: four cases from `4_FBASIC`

| slice | test | instruction | registers | EA per M68000PRM | operand planted at | delta |
| --- | --- | --- | --- | --- | --- | --- |
| `FADD.L/0001.dat`  | t114 | `f236 42a2 64c8` = `FADD.L (-56,A6,D6.W*4),FP5`   | A6=`438FFF00` D6=`00202020` | `43907F48` | `438F7F48` | -64KB |
| `FSNEG.X/0007.dat` | t9   | `f236 495a a2bf` = `FSNEG.X (-65,A6,A2.W*2),FP2`  | A6=`438FFEFA` A2=`00007FF0` | `4390FE99` | `438FFE99` | -64KB |
| `FSNEG.S/0002.dat` | t83  | `f236 46da 2291` = `FSNEG.S (-111,A6,D2.W*2),FP5` | A6=`438FFEFF` D2=`6FFF7FFF` | `4390FE8E` | `438FFE8E` | -64KB |
| `FNEG.B/0002.dat`  | t65  | `f227 589a` = `FNEG.B -(A7),FP1`                  | A7=`438003FE`              | `438003FC` | `438003FD` | +1 byte |

### Two distinct effective-address rules are broken

**(a) Index scaling is applied in 16 bits before sign extension.**  For the
three brief-format cases the planted address matches
`An + (int16)((Xn.W * scale) & 0xFFFF) + d8` exactly, while the architectural
rule -- and `get_disp_ea_020` in `newcpu_common.cpp:412`, which the emulated
CPU itself uses -- is `An + (int32)(int16)Xn.W * scale + d8`:

```
regd = (uae_s32)(uae_s16)regd;   /* sign-extend to 32 bits ... */
regd <<= (dp >> 9) & 3;          /* ... then scale */
```

The two agree until `Xn.W * scale` crosses bit 15, then they differ by
exactly 0x10000.  All three cases sit just past that boundary
(`0x7FF0*2`, `0x7FFF*2`, `0x2020*4`).

**(b) `-(A7)` with a byte operand decrements by 1 instead of 2.**  The
corpus contradicts itself here, which makes this case self-proving: the same
round records the expected post-instruction `A7 = 438003FC`, i.e. the
architectural decrement of two that keeps the stack word-aligned, while the
operand was planted at `438003FD`, one byte higher.  The register model is
right and the placement model is wrong, in the same test.

### Why the round becomes unsatisfiable rather than merely odd

Because the operand never lands on the EA, the generator's emulated read
returns stale bytes from its own long-lived memory image.  Traced back
through the corpus, those bytes come from earlier tests -- in one case from a
different `.dat` file entirely:

| case | EA | generator image | last written by | runtime (restored) |
| --- | --- | --- | --- | --- |
| `FADD.L` t114  | `43907F48` | `D8AFAE1E` | `0001.dat` **test 93** | `00000000` |
| `FNEG.B` t65   | `438003FC` | `3C`       | `0001.dat` **test 117** (t65 is in `0002.dat`) | `41` |

Both expectations reconstruct exactly from the stale values, and both
observed results reconstruct exactly from the restored values.  For
`FADD.L` t114, with FP5 = `401D C4E82B87 9548FE56`:

```
FP5 + (int32)0xD8AFAE1E = 401C EC8F0F87 2A91FCAC   <- corpus expectation
FP5 + (int32)0x00000000 = 401D C4E82B87 9548FE56   <- what real hardware produces
```

`FNEG.B` t65 is the same story one byte wide: `-(int8)0x3C = -60` is the
expectation, `-(int8)0x41 = -65` is what the restored memory yields.

### Suggested fix

Compute the placement address with the same routine the emulated CPU uses to
execute the instruction, rather than a parallel implementation.  Failing
that, the generator already has the consistency check that would catch case
(a) -- `Source address mismatch` at `cputest.cpp:5751` -- but it only runs
when `target_ea[0] != 0xffffffff`, which is not the case for these tests.
Extending it to compare the placement address against the disassembler's
`srcaddr` unconditionally would have flagged all four.

---

## Issue 2: a mid-instruction-stream trace is recorded without fetching vector 9, but the runtime installs an odd vector 9

### Symptom

Every failing round in `4_ODDEXC` and `4_ODDIRQ` reports the same pair:

```
missing trace:    expected 00000009 got 00000000
exception frame:  expected 00000010 got 00000024
```

(21 slices; e.g. `ODD_EXC/CHK.L/0001` t15 r13 and r15, `ODD_EXC/DIVSL.L/0001`
t4 r13/r15, `ODD_EXC/CHK.W/0001` t17 r13/r15.)

### Mechanism

`main.c` installs the odd `exception_vectors` value in **every** vector from
4 upward, vector 9 included (`main.c:483`, `main.c:521`, both guarded only by
`i >= 4`).  The trace handler is therefore unreachable on real hardware: the
first trace fetches vector 9, faults on the odd address, and the round ends
in the address-error handler with frame offset `$24` (9 * 4) and
`tracecnt == 0`.

The generator does not model that fetch.  When a trace is pending and
execution continues, `cputest.cpp` records it internally and clears the flag
without ever touching the vector table:

```c
/* cputest.cpp, "trace after NOP" */
if (trace_store_pc == 0xffffffff) {
    trace_store_pc = regs.pc;
    trace_store_sr = regs.sr;
    flag_SPCFLAG_DOTRACE = 0;
}
```

So in the generator's model the trace is "delivered" for free, execution
proceeds to the end-of-test marker, and it is the marker's own illegal
instruction that faults on its odd vector 4 -- producing the expected frame
offset `$10` (4 * 4) together with `tracecnt == 1`.

This also explains the per-round variance that makes the group look
inconsistent.  A *standalone* trace at `endpc` does go through the vector
table (`Exception(9)` at `cputest.cpp:4501`, gated on
`!test_exception && trace_store_pc == 0xffffffff`) and is then converted by
the odd-vector rule, so those rounds correctly expect `$24`.  Only the
mid-flow rounds are unsatisfiable.

### Suggested fix

Either exempt vector 9 from the odd-vector installation in `main.c` when the
trace feature is active, or model the vector fetch in the generator's
`trace_store_pc` path so a trace on a machine with an odd vector 9 produces
an address error like every other exception.

### Side note, confirming the odd-vector frame rule

While checking the above, `cputest.cpp:1307-1327` was used as the authority
for what an odd-vector address-error frame stacks:

```c
test_exception = 3;
test_exception_addr = feature_exception_vectors;
...
regs.pc = original_exception * 4;
```

That is the vector *offset*, not `VBR + 4*vector`.  Worth stating explicitly
somewhere, because the natural reading of the 68040 manual suggests the
latter and implementations get it wrong.  The corpus is right; the manual is
just terse.

---

## Issue 3 (informational): the generator records but never applies the 68040 odd-RTE stacked-SR quirk the emulator applies

Not a test failure -- the corpus is self-consistent -- but a
generator/emulator divergence noticed while verifying the frames above,
recorded here because it means regenerated data could silently change
behavior.

The mainline emulator models a hardware-verified 68040 quirk
(`newcpu.cpp`, in `Exception_normal`):

```c
if (currprefs.cpu_model == 68040 && nr == 3 && (last_op_for_exception_3 & 0x10000)) {
    // Weird 68040 bug with RTR and RTE. New SR when exception starts. Stacked SR is different!
    x_put_word(m68k_areg(regs, 7), last_sr_for_exception3);
}
```

i.e. on RTE/RTR to an odd PC the NEW (restored) SR selects mode and
stack, but the frame's SR word is the PRE-instruction SR
(`oldsr = regs.sr` before the pop loop, updated across format $1
throwaways), passed via `exception3_read_prefetch_68040bug`.

`cputest.cpp` has the same plumbing -- its
`exception3_read_prefetch_68040bug` stores
`test_exception_3_sr = secondarysr` -- but nothing ever reads
`test_exception_3_sr`, and `doexcstack2`'s cpu_lvl>=4 path stacks
`regs.sr`, the restored SR.  So the corpus's odd-RTE/RTR address-error
frames carry the restored SR, and a CPU implementing the emulator's
(hardware-true, per the comment) quirk would FAIL the AE group's
RTE/RTR rounds.  Either the generator should apply the substitution
like the emulator does, or the dead `test_exception_3_sr` should go.

---

## Reproducing

```
run_cputest.py <corpus> --full --group BasicFPU --instruction 'FADD.L'
run_cputest.py <corpus> --full --group ODD_EXC
```

The four operand-placement cases are visible without any simulator by
walking the `.daz` setup records: decode the memory-write records for the
named tests and compare the record address against the effective address of
the recorded opcode.  The stale-value provenance is visible by accumulating
the setup records across `0001.dat` onward -- note that the generator's
memory image persists across `.dat` files, while the runtime's does not.
