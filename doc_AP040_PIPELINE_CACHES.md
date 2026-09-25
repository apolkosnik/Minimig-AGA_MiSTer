# AP040 pipelined core: instruction and data memory units

Status: design, revision 2 (2026-09-25), after review. Goal: the MC68040's
integrated caches in the pipelined core -- a 4 KB instruction cache and a
4 KB data cache, each beside its own ATC at one of the pipeline's two memory
ports, the data cache write-through or copyback page by page through the
internal MMU, as MC68040UM section 4 describes. Where this platform departs
from the 68040 it says so below; nothing else is intended to differ.

## Where they sit (MC68040UM 4, Figure 4-1)

The instruction memory unit (IMU) serves instruction prefetch and the data
memory unit (DMU) operand accesses. Each translates the logical address in
its ATC while its cache reads the set selected by the untranslated bits
PA9-PA4; the ATC's PA31-PA12 and the untranslated PA11-PA10 are compared
with the four 22-bit tags. Misses, write-through writes and pushes go to the
bus controller below both units.

Today the pipelined core has no cache and translates below its bus
controller: CPU -> ap040_pipe_membus.v -> ap040_mmu.v -> bus16 adapter. The
target:

    port A (IF)  -> IMU: I-ATC lookup + I-cache  \
                                                   > membus (bus controller, physical) -> adapter
    port B (EAF) -> DMU: D-ATC lookup + D-cache  /
                    table walker behind both ATCs; its descriptor reads and
                    writes consult the data cache (below)

## Cache behaviour

Both caches: 64 sets x 4 ways x 16-byte lines, 22-bit physical tags;
replacement takes the first invalid line, else a 2-bit counter advanced as
4.1 describes. A line is loaded only by a complete four-longword line read
(4.1, 4.6.1), the requested longword first and the rest wrapping; the data
is available to the requester as each longword arrives (the line read
buffer), and hits on other lines are served meanwhile.

Instruction cache: one valid bit per line; CACR IE enables it. CPU data
writes do not reach it (4.5): self-modifying code needs CPUSH/CINV.
External snooped writes invalidate matching lines (Table 4-3, V6).

Data cache: a valid bit and four dirty bits per line; CACR DE enables it.
Caching mode per access from the matching TTR or the page descriptor's CM;
translation disabled and no TTR match: write-through (4.3).

| Access | Write-through | Copyback | Cache-inhibited (serialized or not) |
|---|---|---|---|
| read hit | from the cache | from the cache | push the line if dirty, invalidate, bus read |
| read miss | line read, allocate | line read, allocate | bus read |
| write hit | update the line, Dn unchanged, bus write | update the line, set Dn | push if dirty, invalidate, bus write |
| write miss | bus write, no allocation | line read, allocate, update, set Dn | bus write |

A write-through write to a dirty line keeps its Dn bits (Table 4-4, D6, a
programming error the manual still defines). Replacing a dirty line: the
line goes to the push buffer, the new line is read, then the buffer is
written back -- a longword push if one longword is dirty, a line push
otherwise; if the replacement line read is cache-inhibited or errors, the
dirty line returns to its place and a valid line stays invalid (4.6.1, 4.6.2).

Special accesses, each carried to the DMU as request metadata (below):
- exception stacking, vector fetches and table searches never allocate;
  hits are served by the access's mode (4.3.3);
- MOVE16 never allocates; a read hit is served from the cache; a write hit
  invalidates the line and the write goes to the bus (4.3.3);
- locked accesses (TAS, CAS, CAS2, descriptor updates) are noncachable: a
  matching dirty line is pushed and a valid one invalidated before the
  locked transfer (7.4.5);
- MOVES to SFC/DFC $2/$6 becomes a data access in $1/$5 and is handled as
  any data access, cache included; $0, $3, $4 and $7 are alternate-space
  accesses, used untranslated as physical addresses (3.2, Table 3-2), and
  treated here as cache-inhibited. (The pipe's MMU currently translates
  alternate-space MOVES; stage A corrects that.)

CINV (line, page, all; IC, DC, BC) invalidates, discarding dirty data;
CPUSH pushes dirty data lines, then invalidates. Neither depends on CACR.
The line and page forms take a physical address in An.

Table searches: the 68040 serves descriptor reads that hit in the data
cache from the cache (4.3.3), so a descriptor the CPU wrote into a copyback
page is seen by the next search. Here the walker keeps its physical port
for misses, but every descriptor read first looks up the data cache and
uses a hit, and every descriptor history write (U, M) updates a present
line's longword as well as memory, clearing that longword's dirty bit since
memory then matches. The walker uses the DMU's lookup port only while the
DMU is itself waiting on the walk, or by holding the DMU's next request.

## Platform boundary: snooping and DMA

The Amiga chipset cannot drive the 68040's snoop controls: it can neither
source dirty data to a DMA read nor sink a DMA write into a dirty line. What
this platform provides is the "invalidate line" operation (SC = 10) on
every chipset or walker write into memory, applied to both caches as Tables
4-3 and 4-4 define. Consequently:
- a DMA read cannot see dirty data: memory that DMA reads must be
  write-through or inhibited, or pushed by software (CPUSH) first;
- a DMA write into a dirty line loses the line's dirty data;
- so chip RAM and any other DMA-shared memory must be write-through or
  cache-inhibited through the MMU or a TTR -- as 68040.library configures a
  real A4000 -- and copyback is for memory no other master touches.
These are requirements on system software, stated here as the boundary of
"as on the 68040". The FSM wrapper's cacheable windows and its instruction
bypass for chip RAM with the MMU off remain integration options (stage F).

## Storage

Cyclone V M10K: true dual-port at most 20 bits a port; simple dual-port
(one read, one write) up to 40. The M10K column is stage 0's fit of the
arrays alone (tests/ap040/pipe_synth/ap040_pipe_cache_fit.v).

| Array | Organization | Mode | M10Ks |
|---|---|---|---|
| I data | 4 ways x 128 x 64 (a half-line a read) | simple dual-port: read lookups, write fills | 8 |
| I tags | 64 x 88 (a row of four 22-bit tags) | simple dual-port | 3 |
| D data | 4 ways x 256 x 32, byte enables | true dual-port: A lookups and store hits, B fills and push reads | 8 |
| D tags | 64 x 88 | true dual-port: A lookups, B fills and maintenance reads | 5 |
| snoop tags | a copy of each cache's tag rows | simple dual-port, written with the tags | 6 |
| ATCs | 32 rows {bank, set} x 4 ways x 46 | true dual-port, as ap040_mmu.v: A I-lookups, B D-lookups and fills | 8 |

38 of the 5CSEBA6's 553; the FSM core's caches and ATC, which this core
replaces on the card, free a similar number. A tag row holds all four ways,
so a fill reads its row first and writes it back with the new way's tag:
the I side through its lookup port, idle while the unit waits on its own
miss, the D side through port B. Valid, dirty and replacement state in flops
(1,280 bits for the D-cache) so invalidation and dirty updates need no RAM
port -- but tag reads still do: an addressed snoop reads the snoop-tag copy,
line and page maintenance and pushes use port B, a store hit writes port A.

rtl/bram.vhd's dpram has no byte enables. Stage 0 adds a wrapper exposing
altsyncram's byteena on both ports (and its Verilator model); partial stores
write their bytes directly rather than by read-modify-write.

Port use and collisions, per data cache cycle: port A takes a lookup, or a
store-hit write (the store's lookup was two cycles earlier; a lookup of the
same line that cycle is served from the store buffer); port B takes a fill
write, a push read, or a maintenance tag read, in that priority, with the
walker's descriptor lookups taking port A while the DMU waits for the walk.
A snoop reads the snoop-tag copy and clears valid flops; a snoop that hits
the line being filled marks the fill "do not validate"; a snoop that hits
the push buffer's line is recorded against the buffer (the push still
writes -- the DMA-write loss above).

## Performance model (fixed in stage 0, before stage A)

- Hit latency: two cycles on both ports (request, RAM read, tag compare
  into a registered result), one new request per port per cycle. Stage 0's
  fit of the arrays and the ATC alone: the slowest case -- translation on,
  no recent-hit copy: ATC row, ATC tag compare, physical page, the four
  cache tag compares, way select, into the result register -- is the
  worst path, 14.3 ns, 62.9 MHz, +9.1 ns at 25 ns; 874 ALMs of compare
  and select logic.
- Instruction fetch: a half-line (four words) per hit, so the fetch queue
  (ap040_inst_fetch.v) takes up to four words a return and sustains two
  words a cycle with one request outstanding.
- Operand port: one outstanding read in stages B-D (port B's present
  protocol), so a load every two cycles at best; pipelining it is stage E.
- Simultaneous instruction and data hits: yes, the caches are separate.
- Stores: posted into the DMU's store buffer once translated; a load that
  matches a buffered store is served from it (byte-accurate) or waits.
- Hit under miss: the DMU serves hits while a line read completes (4.6.1);
  the IMU serves hits during a data-side miss and vice versa.

## Request metadata and handshakes (defined in stage 0)

From EA-fetch to the DMU, with each port-B request: size and alignment,
read/write, function code (MOVES override, with the $2/$6 conversion and the
alternate-space flag), locked (read and write halves of TAS/CAS/CAS2),
no-allocate (exception stacking, vector fetch), MOVE16 (read or write,
line-sized), and cache maintenance (CINV/CPUSH: IC/DC/BC, line/page/all,
push or invalidate, the physical address from An) with a completion
handshake EX waits on. From the MMU with each translation: the full CM
(2 bits), W, S and M, not ap040_mmu.v's CM[1] alone. Decode carries CINV/
CPUSH's push bit (opcode bit 5), scope (bits 4-3) and register (bits 2-0),
which it currently drops.

## Faults and write-back recovery

A fill that errors on the requested longword's beat faults that access as
today's bus errors do. An error on a later beat aborts the line read and
leaves the line unloaded; it faults only an access actually waiting on that
beat (the second half of a misaligned operand), otherwise the line is read
again when next needed (4.6.1). A failed replacement read restores a dirty
victim from the push buffer.

A push belongs to no instruction: the dirty data came from earlier stores.
The 68040 reports a push bus error as an access error with SSW RW = 0,
TT = 0, TM = 0, a PHYSICAL fault address, the line's four longwords in the
frame's push data fields (PD0-PD3), WB1S invalid and WB2S/WB3S for any
further pending write-backs (8.4.6, Table 8-6), and calls it normally fatal.
The pipe's format-$7 frame builder (ap040_ea_fetch.v) clears every
write-back field today; stage R extends it to carry push data and pending
write-backs, and defines which instruction the exception is taken at. The
same stage defines the posted-write buffer's fault ownership once copyback
exists.

## Stages, each verified before the next

0. Storage and interfaces: the RAM wrappers (rtl/ap040_pipe/ap040_pipe_ram.vhd,
   true dual-port with byte enables and simple dual-port, and their
   Verilator models, tests/ap040/sim_pipe_ram.v, which return junk where
   the silicon is DONT_CARE); the arrays (rtl/ap040_pipe/ap040_pipe_cache_arr.v)
   fitted alone with the ATC -- done, figures above; the request metadata
   and handshakes specified above. Each is implemented with the stage that
   first consumes it, so none is a port nothing drives or reads: the MMU's
   full attributes in A, CINV/CPUSH decode in B, the access attributes and
   the maintenance handshake in C.
A. Translation at the ports: I and D lookup ports on the one ATC RAM, the
   walker behind them; membus physical, reporting only bus errors; faults,
   page-crossing accesses, MOVES spaces, PTEST and PFLUSH at the ports.
   Behaviour-neutral: every suite, the corpus, every MMU program.
B. The instruction cache: half-line fills and reads, the four-word fetch
   queue, CACR IE, CINV/CPUSH on IC, snoop invalidation.
C. The data cache, write-through only: fills with the read buffer, write-hit
   update with byte enables, the store buffer, the special accesses, locked
   accesses, MOVES, table searches through the cache, snoop invalidation,
   CINV/CPUSH on DC.
R. Write-back recovery: fill-beat error rules, push faults and their frame,
   victim restore, posted-write fault ownership -- exercised with forced
   errors before copyback is enabled.
D. Copyback: dirty bits, write allocation, the push buffer, CPUSH pushes,
   pushes before inhibited and locked accesses.
E. Throughput: the pipelined operand port, back-to-back line transfers.
F. Integration: the cacheable windows and snoop inputs on the bus16 top,
   a full-system fit.

## Tests

- Existing programs, corrected: t_cache.s test 6 expects DMA to leave stale
  data, which holds only with snooping suppressed -- run it on a bench mode
  with the snoop off and add the snooped expectation; t_bitfield_cache.s
  writes $00000808 to CACR as "CINV both", which on a 68040 only disables
  the caches (CACR has DE and IE alone) -- use CINVA BC.
- New programs: nonidentity and discontiguous mappings (the set index from
  untranslated bits, the tag from translation); partial byte/word stores
  into present lines; write-through writes to dirty lines; copyback dirty
  data absent from memory until CPUSH or replacement and present after, the
  bench checking memory at points the program names; CINV discarding dirty
  data; locked accesses and MOVE16 on copyback lines; exception stacking
  not allocating; MOVES in each space; dirty page descriptors read and
  updated by the walker; snoops colliding with fills and with the push
  buffer; bus errors on each fill beat and each push beat.
- Differential: the FSM core's cache is write-through only; copyback
  programs are judged on architectural results and on the bench's memory
  checks, not against it.
