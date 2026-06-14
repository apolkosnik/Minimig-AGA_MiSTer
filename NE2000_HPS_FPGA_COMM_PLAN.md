# NE2000 HPS/FPGA Communication Plan

## Scope

Keep the current NE2000/RTL8019/X-Surf-style device model. Do not replace it
with the A2065 Am7990/LANCE register model.

Use the A2065 project only for its proven transport lessons:

- one shared DDR layout with a single source of truth;
- explicit ownership of each mailbox word;
- sequence-based handshakes instead of shared flag read/modify/write races;
- level-held requests and clear drain acknowledgement;
- validated byte-lane and endian handling;
- startup cleanup of stale mailbox state.

## Confirmed Root Cause (2026-06-13, A2065 deep comparison)

Hardware logs show the HPS heartbeat advancing (the HPS reads back its own
writes) while no FPGA-owned status/register-mirror bits ever appear
(`status & 0x7F00 == 0`, `CR=0x00`, `CURR=0x00`). That single fact proves the
HPS and the FPGA are **not addressing the same physical DDR bytes**. Until that
is fixed, every higher-level handshake fails for the same reason.

### The one big difference vs A2065

A2065 made FPGA<->HPS transport reliable with three disciplines the previous
NE2000 transport did not have:

1. **Dedicated f2sdram2 master + round-robin arbiter** for the mailbox,
   separate from the Amiga RAM controller (`a2065_ddr3_mailbox.v` +
   `avalon_arbiter.v`). The old NE2000 core piggybacked the Amiga's own
   `ddram_ctrl`/`DDRAM_*` port (the same 64-bit port used for Amiga fast RAM)
   through a priority-grant mux in `Minimig.sv` (`eth_dma_grant_114`). Path A
   now replaces that with `rtl/eth_ddr3_mailbox.v` and
   `rtl/eth_avalon_arbiter.v` on `ram2`/f2sdram2.

2. **A single, documented address convention with one source of truth**
   (`A2065/arm/include/a2065_ddr3_flat.h`):
   - DDR3 physical base = `0x1FF00000` — a reserved high-DDR window the Linux
     kernel does not use.
   - Avalon (f2sdram2) word address = `ARM_byte_offset >> 3` (the port is
     64-bit, so 8 bytes per word).
   - Stated invariant: "both the 68k (via the FPGA DDR3 window) and the ARM
     (via /dev/mem mmap) access the same bytes." Proven in sim and on hardware.

   The old NE2000 path had **no single source of truth** and a **unit mismatch**.
   `extra/minimig_eth.h` maps the HPS at `0x28EA0000` (= `0x20000000 +
   0x08EA0000`, i.e. inside the Amiga's own DDR map). `rtl/eth_dma_addr_map.v`
   adds a *16-bit-word* base (`28'h4750000`) to a 16-bit-word offset, but
   `rtl/ddram_ctrl.v` then re-slices that value as a *byte* address
   (`{3'b001, cpuAddr[28:3]}` — a >>3 for 64-bit words). A word base consumed by
   a byte-oriented slice cannot land where the HPS reads, and the physical base
   of the `DDRAM_*` port was never proven equal to `0x28EA0000`. Path A now
   uses the A2065 convention directly: HPS physical `0x1FF00000`, Avalon word
   base `0x03FE0000` (`phys >> 3`), with `rtl/eth_dma_addr_map.v` as the RTL
   source of truth and `extra/minimig_eth.h` mapping the same HPS address.

3. **Owner-specific doorbell slots**, one 64-bit DDR word each, with a
   pending/ack handshake and a register-path **watchdog timeout**. (The A2065
   source review's top finding was a *missing* register-path timeout that
   wedged the bridge until core reload; the transferable lesson is "every
   blocking handshake needs a bounded escape.")

### What "behave like A2065" means here (while staying NE2000/RTL8019)

Keep every NE2000/RTL8019 chip semantic (CR/ISR/IMR/DCR, remote DMA, ring
placement, packet RAM ownership) in `rtl/ethernet.v`. Adopt only A2065's
*transport* disciplines:

- One source-of-truth address map shared by RTL and HPS; Avalon word =
  phys >> 3; **prove the HPS and the FPGA touch the same bytes before anything
  else**.
- Chosen transport: **Path A — dedicated mailbox**. The project now uses an
  A2065-style f2sdram2 master and a strict-priority arbiter on `ram2`.
  **Path B — fix in place** is superseded; the old shared-`DDRAM_*` piggyback
  path was the address-mismatch source.
- Owner-specific slots + sequence/doorbell handshakes + bounded timeouts +
  startup clear, exactly as items 2-7 below already describe.

### Decision Taken: Path A on the reserved window (implemented 2026-06-13)

The user chose **Path A** (dedicated f2sdram2 mailbox + arbiter) on the reserved
**`0x1FF00000`** window. This was implemented (see "Implementation Status (Path
A)" at the end of this document). The previous piggyback onto the Amiga
`ddram_ctrl`/`DDRAM_*` port was removed.

Why Path A was clean here: this core's `sysmem_lite` already exposes the
A2065-equivalent dedicated port. `sys/sys_top.v` wires three f2sdram ports —
`ram1`/f2h_sdram1 (Amiga RAM, via the emu `DDRAM_*`), `ram2`/f2h_sdram2
(clk_audio, 64-bit, used by `ddr_svc` for audio/PAL), and `vbuf`/f2h_sdram0
(framebuffer). The mailbox now shares `ram2` with `ddr_svc` through a strict
ddr_svc-priority arbiter, exactly the A2065 structure. The f2sdram address
convention is confirmed: Avalon word = phys byte >> 3, so the HPS base
`0x1FF00000` maps to RTL word base `0x03FE0000` (== A2065's `a2065_ddr3_flat.h`).

## Todo Status (Path A)

Completed:

- [x] Analyze A2065 and the current project; write actionable transport
  differences; update this plan.
- [x] Confirm integration facts: simulation toolchain, Quartus file list,
  `emu` instantiation in `sys/sys_top.v`, and `clk_audio`/`ram2` routing.
- [x] Add `rtl/eth_avalon_arbiter.v`: strict `ddr_svc`-priority two-master
  Avalon arbiter on `ram2`.
- [x] Add `rtl/eth_ddr3_mailbox.v`: `clk_audio` Avalon master with CDC from
  `clk_sys` `eth_dma_*` and 16-bit-to-64-bit lane mapping at `0x1FF00000`.
- [x] Add and run `sim/eth_mailbox_arbiter_tb.v`: lane mapping, byte order,
  read round-trip, backpressure, and no burst corruption.
- [x] Update the address-map source of truth and ABI checks:
  `rtl/eth_dma_addr_map.v`, `sim/eth_dma_addr_map_tb.v`,
  `extra/minimig_eth_abi.h`, and `sim/check_eth_abi.py`.
- [x] Update HPS mapping in `extra/minimig_eth.h` to mmap `0x1FF00000`.
- [x] Wire the mailbox into `Minimig.sv`, wire the arbiter into
  `sys/sys_top.v`, remove the old Ethernet DMA mux onto `ddram_ctrl`, and add
  the new RTL files to `files.qip`.
- [x] Run the Ethernet simulation suite and a full Quartus compile. The latest
  full build succeeded with positive setup and hold slack and generated fresh
  `.sof`/`.rbf` files.

### Hardware bug found and fixed: transmit gated by the RX ring (2026-06-13)

First on-hardware run after Path A: the Amiga boots to Workbench, the X-Surf 100
and RTL8019 are detected, the 16-bit packet-RAM memory test passes, a MAC is
read, and IRQs are received — but a packet send leaves `TSR = 0x00` and the
driver polls ISR (`$EA0C1C`) forever with no PTX.

Root cause (in `rtl/ethernet.v`, not the transport): the transmit trigger was
gated by `(tpsr_register >= pstart_register) && (tpsr_register < pstop_register)`
— it required the *transmit* page (TPSR) to lie inside the *receive* ring
`[PSTART, PSTOP)`. On a standard NE2000 the TX buffer (page `0x40`) sits BELOW
PSTART (`0x46`), so `0x40 >= 0x46` is false and the transmit was silently
dropped: `tx_complete_pending`/staging never set, so TSR/ISR.PTX never assert.
This broke both loopback and normal-mode transmit and is independent of the HPS.

Fix: bound TPSR by the physical packet-RAM page range `[NE_PAGE_BASE, NE_PMEM_END>>8)`
= `[0x40, 0x80)`, not by the RX ring.

The existing `sim/ethernet_tb.v` had masked this by programming `PSTART=0x48,
PSTOP=0x4C, TPSR=0x49` (TPSR inside the ring). It now uses the real driver
layout (`PSTART=0x46, PSTOP=0x80, TPSR=0x40`) and verifies the transmit
completes. Proven non-vacuous: the updated test FAILS against the old gate
("timed out waiting for DMA request") and PASSES against the fix.

### Hardware findings from the X-Surf TestPrg trace (2026-06-13)

The X-Surf `xsurftest` source + register trace (`xsurftest.txt` / `.asm`)
confirmed card detect, 16-bit memory test, **remote-DMA read and write** (1000
bytes, `ISR.RDC` set), and IRQ delivery all work. Two remaining issues were
diagnosed from the test's own code and fixed:

1. **`error TSR = 0x0`, then `No IRQ received / Transmit timeout` — fixed with
   complete-on-command.** The xsurftest "cable" send runs in normal mode
   (`TCR=0`). Originally completion went through the HPS `TX_COMPLETE_SEQ`
   handshake, leaving `TSR=0` without the daemon. A first attempt
   (complete-on-stage: report PTX after the whole frame is copied to the
   mailbox) then produced `No IRQ received / Transmit timeout`, because a
   1500-byte frame is hundreds of word-at-a-time `eth_dma` round trips
   (CDC + arbiter + f2sdram per 16-bit word) — too slow, and stalls entirely if
   the mailbox round trip isn't completing on hardware, so PTX never fired.
   Final fix: **complete-on-command** — `rtl/ethernet.v` reports
   `TSR.PTX`/`ISR.PTX` immediately when `CR.TXP` is written (exactly like a real
   NE2000 accepting the frame, and like the existing loopback path), while the
   packet still stages to the mailbox in the background for the HPS to send.
   Amiga-side transmit completion no longer depends on staging speed, mailbox
   health, or daemon liveness. `sim/ethernet_tb.v` asserts PTX immediately on
   command and separately verifies the background staging still publishes the
   frame; proven non-vacuous (FAILs without the change). Caveat: PTX before
   staging completes means a driver that reuses the TX page for the next frame
   before background staging reads it could corrupt a rapid back-to-back send;
   a burst-staging mailbox or TX double-buffer would remove that window.

2. **"Interrupt Bit ist schon gesetzt / Falsche Karte".** The test
   (`xsurftest.asm:1059-1063`) reads board base + 0x40 (`0xEA0040`) and flags
   bit 7. That is the X-Surf card-level interrupt-status register, which our
   FPGA did not decode, so it read open-bus `0xFF` (bit 7 set) → false
   "interrupt pending / wrong card". `rtl/ethernet.v` now decodes `0xEA0040`
   and returns bit 7 = the NIC interrupt-request line (`|(isr & imr)`).
   `sim/ethernet_tb.v` checks it reads set when PTX is pending and clear after
   the IRQ is acknowledged. (Inferred from the test/driver; refine against
   X-Surf docs if the full interrupt register set is needed by Roadshow.)

Note: complete-on-command makes Amiga **transmit** independent of the daemon,
but actual packet delivery and **receive** still require the HPS `minimig_eth`
daemon to be running and the mailbox round trip to work on real DDR.

### Hardware confirmation + link-status fix (xsurftest2.txt, 2026-06-14)

After flashing the complete-on-command + X-Surf-int-register build, the X-Surf
test confirmed on hardware: `IRQ received ok`, `TSR = 0x01` (PTX) on the send
(no more `error TSR = 0x0` / `Transmit timeout`), and the "Falsche Karte /
Interrupt Bit ist schon gesetzt" message is gone. The test then ended with
`link down!`.

Cause: after a transmit the test switches to page 3 and reads reg 0x17
(`0xEA0C5C`) as a link/media-status register (`xsurftest.asm:1136-1145`): bit0 =
link up, bits[2:1] = speed/duplex (00=10H, 01=10F, 10=100H, 11=100F). But
`0xEA0C5C` was inside the FPGA's data-port alias (`0xC40-0xC5F`), so it returned
remote-DMA data (0) -> bit0 clear -> "link down!". Fix: `rtl/ethernet.v` narrows
the data-port alias to `0xC40-0xC5B` and decodes reg 0x17 (`0xC5C-0xC5F`) as the
link/media-status register, returning `0x0303` (link up, 10 Mbit/s full duplex)
with no data-port side effects. `sim/ethernet_tb.v` checks reg 0x17 reads
`0x0303` (proven non-vacuous: reads `0xFFFF` without the decode).

Remaining hardware gates:

- [ ] Flash the latest `output_files/Minimig.rbf` and confirm the FPGA-owned
  high-byte status bits reach HPS (`status & 0x7F00 != 0`).
- [ ] Confirm CR/CURR mirrors become nonzero after the HPS daemon writes the
  heartbeat/signature.
- [ ] Confirm boot/HRTMon, Amiga-side RTL8019 ID reads, audio, and PAL output
  are unaffected.
- [ ] Run TX/RX packet tests after the mailbox round trip is proven on hardware.
- [ ] After flashing the transmit-gate fix: re-run xsurftest. `TSR` should now
  report `0x01` (PTX) on a loopback send and ISR should set PTX. Capture the new
  log so the remaining two symptoms can be diagnosed with evidence:
  - `PIOWriteMem Timeout!` — a remote-DMA (data-port) write timed out. Only seen
    in the first run, not the xsurftest run whose 16-bit memory test passed; may
    be transient or a large-transfer/data-port-vs-eth_dma interaction. Needs the
    new log to confirm whether it persists once transmit works.
  - `Interrupt Bit ist schon gesetzt … Falsche Karte Prototyp <-> Serientyp!` —
    the X-Surf test's IRQ-behavior probe seeing a stale ISR bit (likely
    ISR.RDC/ISR.RST left set). May be downstream of the failed transmit flow;
    re-check after the gate fix before treating it as a separate bug.

## Current NE2000 Transport

Current project:

- Live NE2000 register state is local in `rtl/ethernet.v`.
- The Amiga register/data-port window is local at card offset `0x0C00..0x0C7F`.
- The card-offset `0x1000..0xFFFF` mailbox is no longer an Amiga CPU memory
  target. `rtl/cpu_wrapper.v` only marks it with `sel_ethernet_shm` for
  diagnostics and HPS/FPGA separation; live FPGA access uses the private
  `eth_dma_*` master in `rtl/ethernet.v`.
- The full configured 64KB card aperture is selected and acknowledged. Only
  `0x0C00..0x0C7F` has RTL8019 semantics; unused/mailbox offsets return
  `0xFFFF` and ignore writes so CPU probes cannot hold the bus forever.
- `rtl/ethernet.v` has a background DMA path (`eth_dma_*`) that writes/reads
  the shared TX/RX/status mailbox through `rtl/eth_ddr3_mailbox.v`.
- HPS code in `extra/minimig_eth.cpp` maps `ETH_SHMEM_ADDR` (`0x1FF00000`) and
  polls/copies packets through that shared area.

A2065:

- Uses a fixed DDR3 shared-memory layout with 64-bit slots.
- Uses separate CMD/CSR/INT/MAC slots with clear ownership.
- Treats the DDR layout as the transport ABI, not as incidental debug memory.
- Verifies address mapping, byte lanes, stale state, and drain handshakes with
  both simulation and MiSTer tests.

## Actionable Differences

### 1. Shared DDR Base And Address Units

Previous state: `extra/minimig_eth.h` mapped HPS physical `0x28EA0000`, while
`rtl/eth_dma_addr_map.v` and `rtl/ddram_ctrl.v` mixed 16-bit-word and 64-bit
word address units. The FPGA and HPS therefore addressed different DDR bytes.

Resolved implementation:

- `extra/minimig_eth.h` maps HPS physical `0x1FF00000`.
- `rtl/eth_dma_addr_map.v` uses f2sdram2 word base `29'h03FE0000`
  (`0x1FF00000 >> 3`) and is instantiated by `rtl/eth_ddr3_mailbox.v`.
- `sim/eth_dma_addr_map_tb.v` checks the recovered HPS byte address for the
  f2sdram2 convention.

Remaining action:

- On hardware, prove the same bytes by checking that FPGA-owned high-byte
  `ETH_CTRL_STATUS` bits and CR/CURR mirrors appear in the HPS log.

### 2. Shared Flag Word Has Mixed Ownership

Previous state: `ETH_CTRL_FLAGS` was modified by both FPGA and HPS. FPGA owned
`TX_REQ/IRQ/ENABLED`; HPS cleared `TX_REQ`, owned `RESET`, and set/cleared
`RX_AVAIL`. This created RMW races and stale-clear hazards.

A2065 avoids this by separating command, status, interrupt, and metadata slots.

Resolved implementation:

- TX uses FPGA-published request address/length/sequence and HPS-published
  completion sequence/status.
- RX uses HPS-produced queue slots and FPGA-owned head/ack advancement.
- FPGA diagnostic/status bits live in the high byte of `ETH_CTRL_STATUS`.
- `ETH_CTRL_FLAGS` remains only as a compatibility/debug mirror.

Remaining action:

- Later cleanup can remove the legacy flag mirror after hardware TX/RX is
  proven.

### 3. TX Completion Should Be Sequence-Based

Previous state: TX publish flow set `ETH_FLAG_TX_REQ`; HPS transmitted then
cleared that flag; FPGA treated the clear as acknowledgement. That depended on
both sides reading and writing the same word correctly.

Resolved implementation:

- FPGA writes packet bytes, then writes request sequence/address/length.
- HPS sends exactly that sequence and writes completion sequence/status.
- FPGA completes `TSR.PTX`, `ISR.PTX`, and clears `CR.TXP` only when
  completion sequence matches the request sequence.
- HPS never clears an FPGA-owned request bit; it only publishes completion.

### 4. RX Should Use Producer/Consumer Slots, Not A Global Flag

Previous state: RX had a shared queue, but queue availability was still tied to
`ETH_FLAG_RX_AVAIL`. That coupled queue ownership to the mixed flag word.

Resolved implementation:

- HPS owns RX producer state: write payload, length/status, then advance tail
  or sequence.
- FPGA owns RX consumer state: copy into local NE packet RAM, update CURR/ISR,
  then advance head/ack.
- HPS may reuse a slot only after FPGA ack has advanced past it.
- Keep the host-side overflow behavior, but count and expose it in HPS status.

### 5. CDC Contract Needs To Be Explicit

Current `Minimig.sv` crosses `eth_dma_req` from `clk_sys` to `clk_114` using a
toggle and samples a multi-bit address/data bundle after the toggle syncs. This
can work only if the source bundle is held stable until completion and no new
request is issued while active.

A2065's lesson is to level-detect busy requests and avoid one-cycle edges that
can be missed while the FSM is busy.

Action:

- Document and enforce one outstanding `eth_dma` request.
- Add RTL assertions or simulation checks:
  - `eth_dma_addr/write/wdata/uds/lds` remain stable while `eth_dma_req` is
    high and before `eth_dma_ready`.
  - no second request starts before the previous ready pulse is observed.
  - ready returns exactly once per request.
- Prefer a level-valid/ready bridge over a rising-edge-only bridge if more than
  one request source is added.
- If the current `ddram_ctrl` arbitration remains flaky, move the NE2000
  mailbox to the A2065-style `f2sdram2` path in `sys_top.v`.

### 6. Byte Lane And Endian Handling Must Be Hardware-Verified

A2065 only became reliable after fixing 68k big-endian vs ARM little-endian DDR
lane interpretation. Current NE2000 HPS code reads raw bytes from
`ETH_NE_MEMORY` and staged RX/TX buffers, while the FPGA writes words through
`ddram_ctrl` with `ramshared` byte swapping.

Action:

- Add a deterministic byte-lane test:
  - FPGA writes bytes `00 01 02 ... 3f` through the NE packet path.
  - HPS verifies exact byte order in mapped memory.
  - HPS writes the inverse pattern and FPGA verifies exact byte order.
- If bytes are swapped in pairs, fix the HPS NE-memory accessors with the same
  `off ^ 1` convention A2065 uses, or fix the FPGA staging writes. Choose one
  convention and document it in `minimig_eth_abi.h`.

### 7. Startup Must Clear Stale Transport State

A2065 clears CMD/CSR/INT slots and pushes a known initial state at daemon start.
Current NE2000 HPS startup writes heartbeat/signature and clears some staging
state in `minimig_eth_reset`, but stale TX/RX sequence state can survive if the
daemon restarts without a core reload.

Action:

- On HPS daemon/init start, clear all live transport slots:
  `TX_CMD`, `TX_DONE`, RX head/tail/lengths, HPS status, stale reset request.
- Then write signature, heartbeat, link status, and MAC.
- FPGA reset should clear its mirrored sequence counters and require a matching
  HPS signature before accepting RX/TX handshakes.

### 8. Register Semantics Should Stay In FPGA

A2065 moved chip semantics to the ARM daemon because LANCE descriptors and CSR
logic were ported from Amiberry. That is not the right fix for the current
NE2000 design.

Action:

- Keep NE2000/RTL8019 register behavior, remote DMA, ISR/IMR, ring placement,
  and packet RAM ownership in `rtl/ethernet.v`.
- Use HPS only for raw Ethernet socket I/O and shared transport servicing.
- Do not introduce A2065 RAP/RDP, CSR shadow, or LANCE ring semantics.

### 9. Amiga CPU Must Not Wait On The HPS Mailbox

The black-screen/INT7 failure points to the 68k being held in a bus cycle. A
direct CPU path into the HPS mailbox made `$EA1000..$EAFFFF` depend on the DDR
bridge. If a driver probe or diagnostic read touched that range while the DDR
path was not returning, the CPU could not reach HRTMon.

Action:

- Select the full configured 64KB Ethernet card aperture in Gary so every CPU
  probe in the autoconfig-assigned board range has a terminating target.
- Keep RTL8019 behavior narrowed inside `rtl/ethernet.v` to the local port
  block `0xEA0C00..0xEA0C7F`.
- Keep `cpu_wrapper` from including `sel_ethernet_shm` in `ramsel`,
  `ramshared`, byte-lane swapping, or `ramaddr` selection.
- Keep `sel_ethernet_shm` only as a marker. Top-level Ethernet DTACK is used to
  terminate the selected card aperture, but the mailbox marker reads as
  `0xFFFF` and never routes to DDR.
- Verify with `sim/cpu_wrapper_ethernet_roundtrip_tb.v` that `$EA1000` marks
  the mailbox, does not select the CPU DDR path, and still completes through
  Ethernet DTACK with `0xFFFF`.

### 10. Data-Port Access Must Have A Bounded CPU Wait

The RTL8019 data port is the only Ethernet access that legitimately waits for
internal transfer completion. A stuck remote-DMA/data-port state must not hold
the 68k forever.

Action:

- Keep `DATA_PORT_TIMEOUT_CYCLES` in `rtl/ethernet.v`.
- On timeout, return `0xFFFF`, clear the local pending state, complete DTACK,
  and set `debug_dma_timeout_sticky`.
- Expose or mirror that timeout in a shared status word so the HPS log can show
  when a CPU-visible data-port timeout happened on hardware.
- Verify with `sim/ethernet_tb.v` that a forced-stuck data-port read completes
  instead of holding DTACK.

## Fix Plan

### Phase 1: Prove And Fix The Address Window

1. Compute the final HPS physical address produced by `eth_dma_addr_map.v` plus
   `ddram_ctrl.v`.
2. Align `ETH_SHMEM_ADDR`, `ETH_SHMEM_BASE_WORD`, comments, and tests.
3. Generate shared ABI constants or add a checked header/test so the C and RTL
   constants cannot drift.
4. Add a non-destructive HPS/FPGA pattern test for every live shared slot.

### Phase 2: Replace Mixed Flags With Owned Slots

1. Extend `minimig_eth_abi.h` with TX/RX/status slots.
2. Update `extra/minimig_eth.cpp` to consume/produce the new slots.
3. Update `rtl/ethernet.v` background FSM to use TX sequence completion and RX
   producer/consumer state.
4. Keep old mirrors for debug only until tests pass.

### Phase 3: Harden The FPGA DDR Request Bridge

1. Add stability checks around `eth_dma_req`.
2. Make timeout behavior visible in a status slot, not only a debug sticky bit.
3. Verify reads and writes under CPU DDR load.
4. If the existing `ddram_ctrl` hook still shows starvation or stale reads,
   migrate the mailbox master to `sys_top.v`/`f2sdram2` using the A2065
   approach.

### Phase 4: Validate Byte Order End-To-End

1. Run simulation for byte enables and odd/even byte writes.
2. Run MiSTer HPS/FPGA byte-pattern tests.
3. Fix either HPS accessors or FPGA staging so packet bytes are wire-order
   correct.
4. Add a TX test that sends a known Ethernet frame and validates it with a host
   packet capture or loopback receiver.

### Phase 5: Startup/Restart Reliability

1. Clear all transport slots at HPS start.
2. Require valid HPS signature/heartbeat before FPGA consumes RX.
3. Reset sequence counters on FPGA reset and HPS reset.
4. Test daemon restart without core reload.

## Current Hardware Triage Notes

The HPS log pattern:

```text
flags=0x00000000, status=0x000C, enabled=0, CR=0x00, rawCR=0x00000000
```

means HPS still sees only its own low status bits. The FPGA high-byte status
bits, CR mirror, and heartbeat-derived fields are not reaching the HPS-visible
DDR mailbox. That is still a FPGA-to-HPS mailbox writeback problem.

The black screen plus INT7 not entering HRTMon is a separate, higher-priority
symptom: it means the 68k is probably stuck in a bus cycle. The current RTL
changes address two Ethernet-owned candidates:

- `$EA1000..$EAFFFF` no longer routes Amiga CPU cycles into DDR.
- The full configured 64KB Ethernet aperture now terminates CPU accesses;
  unused/mailbox offsets return `0xFFFF` rather than becoming unacknowledged
  chip-bus cycles.
- RTL8019 data-port cycles now timeout and return `0xFFFF` instead of waiting
  forever.

After a bitstream containing these changes, test in this order:

1. Boot with Ethernet enabled and press INT7/HRTMon before starting any HPS
   Ethernet daemon.
2. If HRTMon works, read `$EA0C28`, `$EA0C2C`, `$EA0C74`, and `$EA0C70`.
3. If the HPS log still shows only `status=0x000C`, continue with the
   FPGA-to-HPS `eth_dma_*`/CDC/DDR writeback path.
4. If black screen remains, temporarily disable Ethernet autoconfig or the
   top-level Ethernet DTACK override to prove whether any Ethernet bus exposure
   remains in the boot path.

## Build Status

Focused simulations pass for Gary decode, top-level register round trip,
mailbox ABI/lane mapping, CPU-wrapper wait-state behavior, and the Ethernet
data-port timeout.

The full Quartus build completed successfully on 2026-06-13 18:05. Fresh
programming files were generated:

- `output_files/Minimig.sof`
- `output_files/Minimig.rbf`

Current TimeQuest summary:

- Worst-case setup slack: `-0.217 ns`
- Worst-case hold slack: `+0.248 ns`

The full flow generated programming files, but setup timing is slightly
negative and the design still reports incomplete setup/hold constraints. This
build is still useful as a functional black-screen isolation pass, but timing
closure is not clean.

### Phase 6: Network-Level Verification

1. Register access test: CR, ISR, IMR, DCR, remote DMA address/count.
2. Packet RAM test: byte, word, odd/even, wrap at NE memory limits.
3. TX test: Amiga driver transmit causes one HPS send and PTX interrupt.
4. RX test: HPS injects broadcast/unicast frame, FPGA copies to RX ring and
   raises PRX interrupt.
5. Stress test: repeated TX/RX while polling heartbeat/status for several
   minutes; no missed sequence, stale flag, or DDR timeout.

## Recommended First Patch (revised, A2065-aligned)

Start with the shared-memory address proof. It is the highest-leverage issue:
the hardware log already shows the HPS and FPGA are not looking at the same DDR
bytes, so every higher-level handshake is unreliable for that reason alone.

Adopt the A2065 discipline (single source of truth, `Avalon word = phys >> 3`,
"same bytes" invariant) and prove it before touching TX/RX:

1. Establish one source of truth. Generate the shared base + every slot offset
   from a single file (extend `extra/gen_eth_abi.py` / `minimig_eth_abi.h`) and
   have both `rtl/eth_dma_addr_map.v` and `extra/minimig_eth.cpp` consume it.
   No hand-copied constants in RTL and C.
2. Measure the `DDRAM_*` port's real physical base on hardware (do not guess):
   FPGA writes a known marker word through `eth_dma` to slot 0; an HPS scan of
   `/dev/mem` finds the physical address where it lands. That address minus the
   slot offset is the true base. Compare against `ETH_SHMEM_ADDR`.
3. Fix the mapping so the final `ddram_ctrl` DDR write lands exactly on the HPS
   mmap. Resolve the word-vs-byte unit mismatch between `eth_dma_addr_map.v`
   (16-bit-word base) and `ddram_ctrl.v` (`{3'b001, cpuAddr[28:3]}`, byte/>>3).
   If `0x28EA0000` is not physically reachable, move to a reserved window
   (A2065 uses `0x1FF00000`) and update the single source of truth.
4. Update `sim/eth_dma_addr_map_tb.v` to assert the final HPS physical byte
   address (after the full `eth_dma_addr_map` + `ddram_ctrl` transform), not
   just `base + offset`.
5. Only after the heartbeat/signature round-trip succeeds on hardware
   (`status & 0x7F00 != 0`), proceed to the owned-slot TX/RX work (Phase 2+).

## Status After First Implementation Pass

Completed:

- `rtl/eth_dma_addr_map.v` now maps the FPGA ethernet DMA window to the same
  HPS physical `0x28EA0000` buffer used by `extra/minimig_eth.h`.
- `sim/eth_dma_addr_map_tb.v` now checks the final HPS physical byte address
  produced by `eth_dma_addr_map.v` plus the `ddram_ctrl.v` address transform.
- TX no longer depends on HPS clearing `ETH_FLAG_TX_REQ` for completion.
  `rtl/ethernet.v` now publishes `TX_REQUEST_ADDR`, `TX_REQUEST_LEN`, and
  `TX_REQUEST_SEQ`, then completes only when `TX_COMPLETE_SEQ` matches.
- `extra/minimig_eth.cpp` now transmits from the FPGA-staged `ETH_TX_BUFFER`
  and suppresses duplicate sends for an already completed TX sequence. It also
  treats a new `TX_REQUEST_SEQ` as authoritative even if the legacy `TX_REQ`
  flag mirror is stale.
- `sim/ethernet_tb.v` covers TX address/length/sequence publication, staged
  payload writes, and completion-sequence acknowledgement.
- RX now uses the HPS-produced shared queue slots. `rtl/ethernet.v` reads
  `RX_QUEUE_HEAD`, `RX_QUEUE_TAIL`, slot length, and slot payload, then advances
  the FPGA-owned head after copying the packet into local NE packet RAM.
- `sim/ethernet_tb.v` covers RX queue head/tail reads, queue-slot payload
  consumption, head advancement, overrun/drop acknowledgement, stale
  `RX_AVAIL` with an empty queue, and nonzero queue-slot addressing.
- HPS reset now clears the staged TX buffer as well as RX queue data and packet
  metadata, reducing stale bytes after daemon restart.
- `sim/eth_dma_lane_tb.v` now covers the shared DDR write-lane convention,
  final 64-bit byte-enable placement for all word lanes, HPS-visible payload
  byte order for staged TX data, and the mailbox `uint16_t` swap convention used
  by `hps_u16_from_dma`.
- `sim/check_eth_abi.py` compares the HPS ABI header against the RTL shared
  memory parameters so mailbox offsets, queue size, queue slot count, and flag
  masks cannot silently drift.
- HPS reset no longer clears a live FPGA-owned TX request. If
  `TX_REQUEST_SEQ != TX_COMPLETE_SEQ`, the daemon preserves the staged TX buffer
  and TX request mailbox across restart so the pending sequence can still be
  transmitted and completed.
- `rtl/gary.v` now selects the full configured 64KB Ethernet card aperture.
  Earlier builds selected only the RTL8019 port block, which let CPU probes in
  the rest of the autoconfig-assigned card range become unacknowledged chip-bus
  cycles. `rtl/ethernet.v` now acknowledges unused/mailbox offsets with
  `0xFFFF` while keeping real RTL8019 behavior limited to `0x0C00..0x0C7F`.
  `sim/gary_ethernet_decode_tb.v`, `sim/minimig_ethernet_roundtrip_tb.v`,
  `sim/ethernet_tb.v`, and `sim/cpu_wrapper_ethernet_roundtrip_tb.v` cover
  dummy reads from `$EA0000`/`$EA1000` and live RTL8019 ID reads.
- `rtl/minimig.v` now aligns local Ethernet DTACK to the
  `minimig_m68k_bridge` CPU read-data latch phase. The Ethernet module was
  returning nonzero RTL8019 register data, but the CPU could be acknowledged
  before the bridge latched that value onto the CPU-facing data bus.
  `sim/minimig_ethernet_roundtrip_tb.v` reproduces the full read path and
  verifies RTL8019 ID reads return nonzero data at CPU DTACK.
- `rtl/cpu_wrapper.v` now scopes the TG68K `clkena_in` wait-state fix to the
  full configured Ethernet card aperture. Unrelated `ramready` or
  `fastchip_ready` must not let the soft CPU advance during an Ethernet chip
  cycle before `chipdout_i` has latched the read data. This is safe only
  because `rtl/ethernet.v` now terminates every selected card access: RTL8019
  ports return real data, unused/mailbox offsets return `0xFFFF`, and writes to
  unused/mailbox offsets are ignored. `sim/cpu_wrapper_ethernet_roundtrip_tb.v`
  keeps `ramready` high while forcing CPU reads through the wrapper, verifies
  the CPU input bus sees nonzero RTL8019 ID values, and verifies `$EA0000` and
  `$EA1000` retire through Ethernet DTACK with `0xFFFF` without selecting the
  CPU DDR path.
- The FPGA now publishes the shared register/status mirror from reset and after
  normal RTL8019 state changes. The HPS log showed `flags=0`, `CR=0`, and
  `CURR=0` while only the HPS heartbeat advanced, which meant the daemon was
  not seeing FPGA-owned mirror writes. `rtl/ethernet.v` now starts an initial
  mirror sync on NIC reset, requests sync after register writes and remote-DMA
  completion, and samples the HPS heartbeat/signature even while `CR.STA` is
  clear.
- RTL8019 data-port side effects are now one transfer per AS-selected bus
  cycle, not one transfer per transient `cpu_rd/cpu_wr` pulse. The bridge can
  briefly drop `cpu_rd` while AS is still low; treating that as cycle end made
  a station-PROM read advance twice before CPU DTACK. The data-port cycle now
  ends only when the AS-selected data-port access ends.
- The local RTL8019 packet RAM is now inferred as block RAM. The first local
  packet-RAM implementation used one 16-bit array with conditional byte writes;
  Quartus mapped it into logic and failed fit with about `93k` combinational
  nodes for a device with `83k`. `rtl/ethernet.v` now uses split byte-wide
  `mem_l`/`mem_u` arrays, and Quartus infers both as M10K-backed `altsyncram`.
- The HPS poll log now prints the raw transport status word, the raw CR mirror
  dword, and TX request/completion sequence numbers. FPGA communication
  diagnostic bits moved to the high byte of `ETH_CTRL_STATUS` so they no
  longer collide with HPS-owned link/TX status bits.
- A full-line read/modify/write workaround for `ramshared` Ethernet writes was
  implemented and simulated, but not kept. Quartus could not fit that version
  of the design (`93497` combinational nodes required versus `83820`
  available), so the current build stays on the original partial-byteenable
  `ddram_ctrl` path and relies on the new status diagnostics to prove whether
  the real f2sdram write path is the remaining fault.

Current hardware interpretation:

- Latest hardware log sample:
  `status=0x000C`, `enabled=0`, `CR=0x00`, `rawCR=0x00000000`,
  `CURR=0x00`, and only the HPS heartbeat advances. `0x000C` is still only the
  HPS-owned low status bits; it does not contain any FPGA high-byte diagnostic
  bits. The HPS daemon can write/read its own shared window state, but it is not
  seeing FPGA-owned status/register mirror writes yet.
- The black screen plus INT7/HRTMon failure is a separate system-level symptom
  from the Ethernet daemon log. The previous narrowed-decode fix removed the
  CPU-to-DDR mailbox wait but left most of the configured Ethernet card aperture
  without a DTACK source. The current fix makes the whole 64KB card aperture a
  terminating target while keeping the HPS mailbox private to the FPGA/HPS
  `eth_dma_*` path.
- If the HPS log shows `status` with no high-byte FPGA bits
  (`status & 0x7F00 == 0`), the FPGA is not completing the HPS
  heartbeat/signature round trip through DDR. The remaining failure is below
  `rtl/ethernet.v`: top-level Ethernet DMA CDC, `ddram_ctrl` on real f2sdram,
  or the physical DDR window.
- If the HPS log shows high-byte FPGA bits such as `0x0700` or `0x1F00` but
  `CR=0x00`/`rawCR=0x00000000`, then the DDR path works and the bug is in the
  register mirror sync sequence.
- With a working DDR bridge, reset/stopped NIC state should still publish
  `CR=0x21`, `CURR=0x47`, and a nonzero high-byte `status` once the daemon has
  written heartbeat/signature.

Still actionable:

- The shared flag word is still a compatibility/debug mirror. TX no longer
  relies on flag clearing for completion, and RX no longer depends on
  `ETH_FLAG_RX_AVAIL` to discover queued packets. The flag word still exists
  for compatibility and should be replaced with fully owner-specific status
  slots later.
- Byte-lane behavior is now covered by focused simulation, but still needs a
  hardware round-trip test against the actual mapped DDR window before treating
  packet byte order as proven end-to-end.
- Daemon restart while an FPGA TX request is already pending is addressed in
  code, but still needs a hardware test to prove there is no duplicate or
  stranded TX across an actual process restart.
- The RTL8019 local aperture and DTACK alignment fixes pass simulation, but
  still need a MiSTer hardware smoke test that reads the RTL8019 ID registers,
  reset/debug ports, and remote-DMA data port through the Amiga side.
- The full-aperture CPU-wrapper ready/DTACK fix passes focused Verilator
  simulation, and the
  full Quartus build completes with programming files. It still needs a
  hardware boot/HRTMon smoke test and an Amiga-side RTL8019 readback test on
  the exact CPU core configuration used in the failing setup.
- The full Quartus build fits, but TimeQuest still reports setup timing not met
  (`worst setup slack = -0.217 ns` in the latest build). Treat this as a
  separate timing-closure item from the HPS/FPGA transport bug.
- If the next HPS log still shows `CR=0x00`, use the new `status` field to
  split the fault: no high-byte FPGA bits means the DDR round trip is failing;
  high-byte FPGA bits with `rawCR=0x00000000` means the mirror sync sequence is
  failing after the DDR path has already proven alive.

## Implementation Status (Path A, dedicated f2sdram2 mailbox) — 2026-06-13

The HPS<->FPGA transport was rebuilt as an A2065-style dedicated f2sdram2
mailbox. The NE2000/RTL8019 device model in `rtl/ethernet.v` is unchanged; only
the transport beneath the `eth_dma_*` interface changed.

New RTL:

- `rtl/eth_ddr3_mailbox.v` — bridges the 16-bit `eth_dma_*` master (clk_sys)
  to a 64-bit Avalon-MM master (CLK_AUDIO). Does the clk_sys<->clk_audio CDC
  (one outstanding request, toggle handshakes), the 16-bit<->64-bit lane
  mapping, and the byte-swap/byteenable convention (identical to the old
  `ddram_ctrl` path, verified by `sim/eth_dma_lane_tb.v`). Instantiates
  `eth_dma_addr_map` so the base lives in one place.
- `rtl/eth_avalon_arbiter.v` — strict ddr_svc-priority 2-master Avalon arbiter
  sharing the `ram2`/f2sdram2 port. m0 = `ddr_svc` (audio/PAL, priority,
  read-only bursts); m1 = the mailbox (single-beat). Grant is held until read
  responses drain, so `readdatavalid` is always routed correctly. The mailbox
  can never starve or corrupt audio/PAL DMA.

Changed:

- `rtl/eth_dma_addr_map.v` — now the single RTL source of truth for the base:
  `ETH_F2SDRAM_BASE_WORD = 29'h03FE0000` (= `0x1FF00000 >> 3`), with the new
  64-bit-word mapping `base + local_word_addr[15:3]`.
- `extra/minimig_eth.h` — `ETH_SHMEM_ADDR = 0x1FF00000` (reserved high DDR; the
  HPS mmaps `/dev/mem` here so FPGA and ARM touch the same bytes).
- `Minimig.sv` (emu) — removed the old `eth_dma` clk_114 CDC and the mux onto
  the Amiga `ddram_ctrl`; restored that controller to CPU-only; instantiates
  `eth_ddr3_mailbox` (CLK_AUDIO) and exposes its Avalon master via new
  `ETH_MBX_*` emu ports.
- `sys/sys_top.v` — `ddr_svc` now drives a private `dsvc_*` master;
  `eth_avalon_arbiter` arbitrates `dsvc_*` (m0) and the emu `ETH_MBX_*` (m1)
  onto `ram2_*`; the emu `ETH_MBX_*` ports are connected.
- `files.qip` — adds the two new RTL files.

Verified in simulation (Icarus Verilog) and the Quartus build:

- `sim/eth_mailbox_arbiter_tb.v` (new) — drives the mailbox via `eth_dma`
  through the arbiter into a behavioral f2sdram slave with read latency and
  backpressure; checks lane/byte layout, read round-trip, an HPS-written value,
  and that concurrent `ddr_svc`-style burst reads (m0) are uncorrupted while
  mailbox traffic (m1) interleaves. PASS across two async clocks.
- `sim/eth_dma_addr_map_tb.v` — rewritten for the f2sdram convention; asserts
  the recovered HPS physical byte address == `0x1FF00000 + window offset`. PASS.
- `sim/eth_dma_lane_tb.v`, `sim/ethernet_tb.v`, `sim/gary_ethernet_decode_tb.v`
  — PASS (byte convention and `eth_dma`/RTL8019 behavior unchanged).
- `sim/check_eth_abi.py` — PASS (31 checks; window offsets unchanged).
- Quartus `--flow compile Minimig` — passes Analysis & Elaboration with the new
  hierarchy (`eth_avalon_arbiter:eth_arb`, `emu|eth_ddr3_mailbox|eth_dma_addr_map`)
  and no wiring errors.

Remaining hardware gate (cannot be verified off-target):

- Confirm the f2sdram2 (`ram2`) port physically reaches `0x1FF00000` on the
  DE10-Nano (A2065 proved this base works on the same platform). On hardware,
  the FPGA-owned high-byte `status` bits should finally appear in the HPS log
  (`status & 0x7F00 != 0`), and `CR`/`CURR` mirrors should become non-zero.
- Confirm audio and PAL output are unaffected by sharing `ram2` through the
  arbiter (the priority policy and burst-no-corruption are proven in sim, but
  validate on hardware).
- Re-run the heartbeat/signature round trip, then TX/RX, per Phase 6.
