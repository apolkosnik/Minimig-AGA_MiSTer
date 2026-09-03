# AP040 stage B0: the pipeline's stage boundaries, agreed before code

Plan reference: AP040_IMPLEMENTATION_PLAN.md, Part X3, X3.6 (stage B).
Written 2026-09-02 against branch ap040x3 @ 0d761ba, from the measured
state histograms and the core as it stands after the memory-path stages
(A2a, A2b, A1).  This is the document X2.3a asked for and X3.6 makes the
first deliverable of B: what each pipeline register carries, what the
control word looks like, which instructions are fast-path and which are
sequenced, and how the exception model survives.  Nothing here is RTL.

## 0. Why a pipeline, in the numbers that remain

After A2a/A2b/A1 the memory path no longer sets the cost of the common
instructions.  bench_store's histogram puts a store at ~13.5 cycles, of
which ~8 are one FSM state each (S_FETCH, S_DECODE, S_PIPE_START,
S_EA_DISP, S_EA_BASE, S_PIPE_DST, S_PIPE_DEA, S_EXEC) and 5.5 the
handshake; a load is ~11 of the same shape; a register op is 5.7.  The
loop benchmark (move.l (a0)+,d0 / add.l d0,d2 / dbra) runs at 25.4 cycles
per iteration, 8.5 per instruction, with 0% bus stall.  Where those
cycles go, t_integer phase 0 (11,577 cycles):

    S_FETCH       3892   34%   one per instruction word consumed
    S_IMMF        2082   18%   one per extension/immediate word
    S_MRD         1145   10%   loads (2.2-cycle cache hit + issue)
    S_DECODE       918    8%   one per instruction
    S_MWR          623    5%   stores (the 5.5-cycle handshake)
    S_EXEC         607    5%   one per ALU instruction
    S_PIPE_START   607    5%   one per ALU instruction
    S_PIPE_REGS    489    4%   register-register operand read
    S_MD_WAIT      195    2%   multiply/divide iterations
    EA states      ~250   2%   (An), d16(An), abs, index forms

Every row above except S_MRD/S_MWR's memory cycles and S_MD_WAIT is a
sequencer state that a pipeline overlaps.  The target CPI is 1.3-1.5 on
register code and ~2 on load/branch loops; at 28 MHz that is the 25 MHz
68040's throughput, and it is the only stage that reaches it.

## 1. What stays, what goes

Stays, unchanged in interface:
  ap040_regfile (two combinational read ports, one write, banked A7)
  ap040_alu (single-cycle ALU + barrel shifter + bit ops, CCR rules)
  ap040_muldiv (DSP multiply, 4-bit/cycle divide, start/done)
  ap040_fpu (its request/scoreboard interface, exception model intact)
  ap040_mmu, ap040_cache, ap040_bus16_adapter, the fill channel, the
    posted store and its drain
  the exception frame formats and their builders (exc, aerr_start,
    u_rec, the format-$7 layout, the FPU frames), the trace/interrupt
    rules (fetch_next's ordering, tb_must's IPEND rule), MOVEC/MMU/cache
    sideband protocols

Goes: the 188-state main FSM and the 1,100-line S_DECODE case in
ap040_core.v.  What replaces them is below.  The fetch queue's storage
and page-guard logic stay as IF's front end.

## 2. Stages

    IF   PC generator + the existing 8-word queue.  Presents up to
         three words (opcode + two extension words) to ID per cycle
         when resident.  Taken branch / flush: redirect, queue re-armed
         at the target (existing epf_flush + issue_ifetch).
    ID   Classify the opcode (combinational classifier, section 4) ->
         class index -> control word from the control store; count and
         consume extension words; read the two register ports for the
         operands the class names.  Sequenced classes divert to the
         microsequencer here (section 5).
    EA   Effective address: base + scaled index + displacement, one
         adder; PC-relative uses the instruction's PC; postincrement /
         predecrement produce the updated An here and forward it.
         Immediates and register operands pass straight through.
    MEM  Data access: translate (MMU), cache lookup, load data or
         store issue.  Misaligned and page-crossing accesses become a
         multi-cycle MEM sequence (the existing S_MRD_B/S_MWR_B logic,
         now owned by MEM), stalling the stages behind.
    EX   ALU / shift / bit op / CCR; multiply-divide launch (the unit
         runs on, EX-side scoreboard on the destination); branch
         resolution (condition against CCR); CHK/TRAPcc decisions.
    WB   Commit: register and CCR writes, store hand-off to the cache
         (already posted/drained there), the ONLY point that changes
         architectural state.  Faults, traces and interrupts are
         decided here (section 6).

Six stages, one instruction per stage per cycle on the fast path.  A
register op is IF-ID-EX-WB (EA and MEM pass through in one cycle each
for uniformity; a later optimization may let ID feed EX directly).

## 3. Pipeline registers (what each carries)

IF/ID (per instruction word group)
    pc_i[31:0]        address of the opcode
    ir[15:0]          opcode
    ext0[15:0], ext1[15:0], ext_valid[1:0]   words already resident
    sr_s              supervisor state at fetch (FC for the fetch)
    valid, fault      a deferred prefetch fault rides with its word
                      (today's epf_err rule: only if executed)

ID/EA
    ctrl[CW-1:0]      the control word (section 4)
    pc_i, ir           for exception frames and PC-relative EA
    src_kind, src_reg, dst_kind, dst_reg, op_size
    ea_mode, ea_rn, ea_size, ea_disp[31:0], ea_idx_sel, ea_scale,
      ea_pcrel, ea_bd_size, ea_od (full extension word decode)
    imm[31:0]          immediate operand, sized
    ra[31:0], rb[31:0] register operands read in ID (forwarded later)
    trace_t1, trace_t0_special

EA/MEM
    ctrl, pc_i, ir, op_size
    ea_addr[31:0]      the effective address
    an_upd[31:0], an_upd_reg, an_upd_valid   post/predecrement result
    src_val[31:0]      register or immediate source, else from MEM
    dst_val[31:0]      register destination value (RMW reads in MEM)
    rmw, store, load flags

MEM/EX
    ctrl, pc_i, ir, op_size, ea_addr
    src_val, dst_val   both operands resolved
    fault info         (translation fault: aer_* fields as today)

EX/WB
    ctrl, pc_i, ir
    result[31:0], flags[4:0], flags_mask
    dst_kind, dst_reg, dst_addr (store), store_data
    exc_kind, exc_vec  (CHK, TRAPcc, divide-by-zero, privilege, ...)
    md_launched        the multiply/divide is in flight (scoreboard)

## 4. The control word and the two-level decode

The decoder becomes a small combinational CLASSIFIER (ir[15:12] plus
the field patterns S_DECODE already tests) that yields a class index
(8 bits: ~180 classes cover the 68040 integer set) and a CONTROL STORE
in block RAM, 256 x 48 bits (one M10K), indexed by class:

    ek[3:0]        exec kind: ALU, SHIFT, MD_W, MD_L, CHK, SCC, PACK,
                   UNPK, FLOW, NONE   (the existing EK_* plus FLOW)
    alu_op[5:0]    the ALU operation (AP040_ALU_*), or shift kind
    size_sel[1:0]  fixed size, or "from ir[7:6]", or "from ir[8]"
    src_kind[2:0]  NONE/REG/IMM/MEM/IMPL   (SK_*)
    src_sel[1:0]   which ir field names the register (d_reg9, d_rn)
    dst_kind[2:0]  NONE/REG/MEM/SR/CCR     (DK_*)
    dst_sel[1:0]
    ea_src[1:0]    which ir field carries the EA (mode/rn at [5:0] or
                   the MOVE destination at [11:6])
    imm_kind[1:0]  none / sized immediate / quick (ir[11:9]) / ext word
    flags_mask[4:0] which CCR bits the result writes
    rmw, wbsup     read-modify-write; suppress writeback (TST/CMP/BTST)
    flow[2:0]      none / Bcc / BRA / BSR / JMP / JSR / RTS / DBcc
    priv           supervisor only
    serialize      drains the pipeline before commit (MOVE to SR, MOVEC,
                   CINV/CPUSH, PFLUSH/PTEST, STOP, RESET, RTE)
    sequenced      not a fast-path class: divert to the microsequencer
    t0_special     the 68040 T0 trace list
    ill            reserved / illegal encoding for this class

The classifier is where S_DECODE's KNOWLEDGE moves; what it loses is the
per-class sequencing, which the stages and the control word carry.  The
control store is generated from a table (tests/ap040/pipe_ctrl.py, to
be written) so the same table drives a decode unit test that compares
class + control word against the old S_DECODE's decisions over every
16-bit opcode -- the equivalence gate for B1.

## 5. Fast path versus sequenced

Fast path (pipelined, one per cycle when hazards allow) -- these are
every row of the histograms above:
  MOVE/MOVEA all sizes, all EA modes incl. full extension words
  ADD/SUB/AND/OR/EOR/CMP/TST/NEG/NOT/CLR/EXT/EXTB/SWAP, the I/Q/A forms
  ADDX/SUBX/NEGX register forms, MOVEQ, LEA, PEA
  shifts and rotates by immediate or register (single-cycle barrel)
  bit ops BTST/BCHG/BCLR/BSET, static and dynamic
  Scc Dn, DBcc, Bcc/BRA/BSR (8/16/32), JMP/JSR/RTS/RTD, NOP
  MULU/MULS/DIVU/DIVS word and long: EX launches the unit, the
    destination is scoreboarded, the next reader stalls (today's
    S_MD_WAIT becomes a stall, not a state)
  CHK, TRAPcc, TRAPV, TRAP (exceptions decided in EX, taken at WB)
  MOVE to/from CCR (SR forms serialize, below)

Sequenced (microsequencer takes ID, the pipeline drains behind it, the
existing state code is kept as a microsequence with its own tests):
  MOVEM, LINK/UNLK (multi-word memory sequences)
  CAS/CAS2/TAS (locked RMW; lk_cyc semantics unchanged)
  bitfield instructions, CHK2/CMP2, MOVE16, MOVEP, PACK/UNPK, BCD ops
  MOVE to SR, MOVE USP, MOVEC, MOVES, RTE, RTR, STOP, RESET
  CINV/CPUSH, PFLUSH, PTEST (the sideband waits: post_busy, epf_pend)
  all F-line (the FPU interface as today; FSAVE/FRESTORE)
  exception entry and the reset sequence (exc, aerr_start, u_rec)

The split is by measurement: everything in the fast path is in the top
rows of t_integer/bench_loop/bench_store; everything sequenced is rare
in those and correctness-heavy in cputest.  The microsequencer is the
present FSM's state code for those classes, entered from ID with the
pipeline empty, so its cputest-proven ordering does not change.

## 6. Hazards and forwarding

  Dn/An RAW        EX->EA and WB->EX forwarding; address-register
                   updates from (An)+/-(An) forward EA->EA (the loop
                   pattern move.l (a0)+ ; move.l (a0)+).
  load-use         MEM result feeding the next EX: one-cycle stall.
  CCR              EX writes flags; the next EX (or a branch resolving)
                   forwards them; Scc/Bcc right behind an ALU op cost 0.
  multiply/divide  destination scoreboard; a reader stalls until done;
                   a second launch waits.
  stores           data from EA/MEM (register source) or from MEM (the
                   mem-to-mem MOVE): the latter serializes source load
                   and store in MEM.
  branches         resolved in EX; taken: flush IF/ID/EA, redirect --
                   two to three cycles, no prediction (silicon has
                   none; its taken-branch cost is the same 2-3).
  serialize        control word bit: the instruction waits at ID until
                   the pipeline is empty and post_busy/epf_pend are
                   clear, then runs alone.

## 7. Exceptions, traces, interrupts: the restart model, kept

Every fault is recorded in the pipeline register of the instruction it
belongs to and TAKEN at WB: older instructions have committed, younger
ones are flushed, and the frame is built from the recorded pc_i, ir and
fault fields by the existing builders (exc for formats $0/$2, aerr_start
for format $7, u_rec).  The restart shortcut holds: no partially
committed instruction exists, because commit happens at WB only and a
sequenced instruction runs with the pipeline empty.  Format $7's WB
slots stay synthetic; the posted store's post_err halt stays.

Prefetch faults ride with their word (IF/ID.fault) and are taken only
if that word reaches WB -- the epf_err rule, unchanged.

Interrupts and traces are sampled at WB after an instruction commits,
with fetch_next's priority (an interrupt already pending at the boundary
outranks a simultaneous trace; the trace is delivered at the handler's
entry through the texc machinery).  tb_must (the IPEND rule) and the
walker-versus-bus rule are the acceptance checks, as they were for A2b.

## 8. Memory interface

One MEM stage, one outstanding data access (the cache is a single-
request machine); instruction fetch through the queue as today.  The
posted store and its drain, the fill channel and the write-hit update
are all below MEM and unchanged.  A3's second lookup (after P2) is what
lets MEM and IF miss concurrently; until then MEM's miss stalls IF's
miss and vice versa, exactly as now.

## 9. Staging and switches (X3.6)

  B0  this document; tests/ap040/pipe_ctrl.py and the decode
      equivalence test (class + control word vs S_DECODE over all
      65,536 opcodes) -- the first code, and it touches no RTL path.
  B1  IF/ID with the control store, fast path only, behind
      AP040_PIPE=0/1; sequenced classes and everything not yet ported
      trap into the existing FSM, which stays whole.  Gate: AP040_PIPE=0
      bit-matches HEAD's logs; AP040_PIPE=1 green on the five programs
      with the fast-path classes executing in the pipe.
  B2  EA/MEM for the fast path: loads and stores, all EA modes.
  B3  EX/WB, forwarding, scoreboard; the cputest corpus every commit
      from here (data040, 3801 slices, the failing set unchanged).
  B4  fold the sequenced classes in as microsequences; retire the FSM.
      This is where the area drops.
  B5  area and timing: ap040_core <= 13.1K ALMs (smaller than the FSM
      it replaces), clk_sys slack not below today's +0.9 ns.

Gate for B as a whole: CPI <= 1.5 on t_integer's register blocks and
<= 2 on bench_loop; corpus unchanged; all three differentials; T1.

## 10. Open questions, to settle in B1

  * Where extension words are consumed when the queue holds fewer than
    the instruction needs: ID stalls (simplest) or IF pre-assembles a
    variable-length word group (faster, more logic).  Start with the
    stall; measure.
  * Whether register operands are read in ID or EA.  ID keeps EA's
    adder free for addresses only; the forwarding network is the same
    either way.
  * The MOVE mem-to-mem class (two EAs): fast path with a two-beat MEM,
    or sequenced.  It is common enough (structure copies) to want the
    fast path; B2 decides on the measured cost of the two-beat MEM.
  * Whether the classifier can be a ROM too (a 64K x 8 M10K table is
    64 blocks -- affordable, but the combinational classifier is the
    existing S_DECODE knowledge and easier to keep equivalent).
