/*
 * a2065_ddram_arbiter.v
 *
 * Two-master Avalon-MM arbiter for the core's DDR3 port (the emu DDRAM_*
 * interface).  Master 0 is the Minimig fast-RAM controller; master 1 is the
 * A2065 DDR3 mailbox.
 *
 * Fixed priority, master 0 wins.  m0 carries every 68k fast-RAM access, so it
 * must never be made to wait on the A2065: a stalled fast-RAM path hangs the
 * Amiga, while a stalled mailbox only delays a network register poll by a few
 * cycles.  m1 issues one single-beat transfer at a time and polls at a low
 * rate, so it takes the gaps between m0's bursts and loses nothing in practice.
 *
 * Arbitration is per burst, decided when a burst starts and held until it
 * completes, since Avalon gives no way to interleave two masters' beats on one
 * slave.  Reads and writes complete differently:
 *
 *   write burst  done after burstcount beats have been accepted (!waitrequest)
 *   read burst   done after burstcount beats have returned (readdatavalid)
 *
 * The single-beat case needs care: the start of a burst and its first accepted
 * beat happen in the same cycle, so that beat is counted at the point the
 * burst is granted rather than by the tracking block, which would otherwise
 * still see burst_active low and miss it.  Getting this wrong leaves the
 * arbiter latched to one master forever.
 */

module a2065_ddram_arbiter #(
    parameter ADDR_W  = 29,
    parameter DATA_W  = 64,
    parameter BURST_W = 8,
    parameter BYTE_W  = 8
)(
    input  wire                clk,
    input  wire                rst,

    // Master 0 — Minimig fast RAM (priority)
    input  wire [ADDR_W-1:0]   m0_address,
    input  wire [BURST_W-1:0]  m0_burstcount,
    input  wire                m0_read,
    output wire [DATA_W-1:0]   m0_readdata,
    output wire                m0_readdatavalid,
    input  wire [DATA_W-1:0]   m0_writedata,
    input  wire [BYTE_W-1:0]   m0_byteenable,
    input  wire                m0_write,
    output wire                m0_waitrequest,

    // Master 1 — A2065 mailbox
    input  wire [ADDR_W-1:0]   m1_address,
    input  wire [BURST_W-1:0]  m1_burstcount,
    input  wire                m1_read,
    output wire [DATA_W-1:0]   m1_readdata,
    output wire                m1_readdatavalid,
    input  wire [DATA_W-1:0]   m1_writedata,
    input  wire [BYTE_W-1:0]   m1_byteenable,
    input  wire                m1_write,
    output wire                m1_waitrequest,

    // Slave — DDR3
    output wire [ADDR_W-1:0]   s_address,
    output wire [BURST_W-1:0]  s_burstcount,
    output wire                s_read,
    input  wire [DATA_W-1:0]   s_readdata,
    input  wire                s_readdatavalid,
    output wire [DATA_W-1:0]   s_writedata,
    output wire [BYTE_W-1:0]   s_byteenable,
    output wire                s_write,
    input  wire                s_waitrequest
);

    localparam M0 = 1'b0;
    localparam M1 = 1'b1;

    reg               busy;          // a burst is in flight
    reg               owner;         // which master owns it
    reg               owner_is_read;
    reg [BURST_W:0]   beats_left;
    reg [BURST_W:0]   stale_beats;   // abandoned burst's beats still owed

    wire m0_req = m0_read | m0_write;
    wire m1_req = m1_read | m1_write;

    // While idle, m0 wins outright; m1 is granted only when m0 is quiet.
    // No new READ may start while an abandoned burst's beats are still
    // quarantined: in-order Avalon offers no tags, so a response arriving
    // during that window can only be attributed by position -- admitting a
    // read would let the swallow logic eat ITS beats (a lost response) or
    // let the stale beats complete it (a late one).  Reads therefore wait
    // out the quarantine, which either drains (beats arrive, swallowed) or
    // decays (nothing arrives for a full timeout window -- far beyond any
    // functioning bridge's latency, so the response is genuinely lost).
    // Writes consume no read beats and remain safe to admit.
    wire       rd_hold  = (stale_beats != 0);
    wire       start_m0 = !busy && m0_req && !(m0_read && rd_hold);
    wire       start_m1 = !busy && !m0_req && m1_req && !(m1_read && rd_hold);
    wire       sel      = busy ? owner : (m0_req ? M0 : M1);
    wire       starting = start_m0 | start_m1;

    wire [BURST_W-1:0] sel_burstcount = (sel == M0) ? m0_burstcount : m1_burstcount;
    wire               sel_read       = (sel == M0) ? m0_read       : m1_read;
    wire               sel_write      = (sel == M0) ? m0_write      : m1_write;

    // A beat is accepted whenever the slave takes a write, or a read command is
    // issued. Read data comes back later and is counted by readdatavalid.
    wire write_beat = sel_write && !s_waitrequest;

    // Response watchdog.  A read burst whose data never returns used to
    // latch busy/owner forever, blocking BOTH masters -- once wedged, even
    // the CPU's bus-error exception could not stack (its frames live in
    // the same DDR3), so the machine died silently.  After RD_TIMEOUT
    // cycles with beats outstanding and no readdatavalid, abandon the
    // burst: clear busy so new bursts can start, and remember how many
    // beats of the dead burst are still owed so that, if the slave later
    // delivers them, they are SWALLOWED here rather than routed to a newer
    // burst's master (the late-response aliasing hazard).
    localparam RD_TIMEOUT_BITS = 14;
    reg [RD_TIMEOUT_BITS-1:0] resp_wait;
    // In-order Avalon cannot distinguish a LATE response from a LOST one.
    // Quarantined beats therefore decay: if no beat at all arrives within
    // the same timeout window, the abandoned response is presumed lost and
    // the quarantine lifts -- otherwise it would swallow the next real
    // burst's beats and re-wedge the very reads it exists to protect.
    reg [RD_TIMEOUT_BITS-1:0] stale_wait;
    wire stale_swallow = (stale_beats != 0) && s_readdatavalid;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            busy          <= 1'b0;
            owner         <= M0;
            owner_is_read <= 1'b0;
            beats_left    <= 0;
            resp_wait     <= 0;
            stale_beats   <= 0;
            stale_wait    <= 0;
        end
        else begin
            if (stale_swallow) begin
                stale_beats <= stale_beats - 1'b1;
                stale_wait  <= 0;
            end
            else if (stale_beats != 0) begin
                if (&stale_wait) begin
                    stale_beats <= 0;   // presumed lost, lift quarantine
                    stale_wait  <= 0;
                end
                else stale_wait <= stale_wait + 1'b1;
            end

            if (!busy) begin
                resp_wait <= 0;
                if (starting && !s_waitrequest) begin
                    owner         <= sel;
                    owner_is_read <= sel_read;
                    if (sel_read) begin
                        // The whole read burst is issued as one command; every
                        // beat is still outstanding until its data comes back.
                        busy       <= 1'b1;
                        beats_left <= sel_burstcount;
                    end
                    else begin
                        // The first write beat is placed in this same cycle, so
                        // only the remainder is outstanding.
                        busy       <= (sel_burstcount > 1);
                        beats_left <= sel_burstcount - 1'b1;
                    end
                end
            end
            else if (owner_is_read ? (s_readdatavalid && !stale_swallow)
                                   : write_beat) begin
                resp_wait  <= 0;
                beats_left <= beats_left - 1'b1;
                if (beats_left == 1) busy <= 1'b0;
            end
            else if (owner_is_read) begin
                if (&resp_wait) begin
                    // abandon: free the port, quarantine the owed beats
                    busy        <= 1'b0;
                    stale_beats <= stale_beats + beats_left;
                    beats_left  <= 0;
                    resp_wait   <= 0;
                end
                else resp_wait <= resp_wait + 1'b1;
            end
        end
    end

    // Read data returns out of band. Only one read burst is ever in flight
    // (a new burst cannot start while busy), so remembering the owner of the
    // most recent one is enough to route it.
    reg rd_owner;
    always @(posedge clk or posedge rst) begin
        if (rst) rd_owner <= M0;
        else if (!busy && starting && !s_waitrequest && sel_read) rd_owner <= sel;
    end

    assign s_address    = (sel == M0) ? m0_address    : m1_address;
    assign s_burstcount = (sel == M0) ? m0_burstcount : m1_burstcount;
    assign s_read       = ((sel == M0) ? m0_read : m1_read) && !rd_hold;
    assign s_writedata  = (sel == M0) ? m0_writedata  : m1_writedata;
    assign s_byteenable = (sel == M0) ? m0_byteenable : m1_byteenable;
    assign s_write      = (sel == M0) ? m0_write      : m1_write;

    // Back-pressure. A master that is merely idle must see the slave's own
    // waitrequest, not a busy signal: ddram_ctrl only issues a request while
    // ~DDRAM_BUSY, so holding an idle master off would stop it ever asking,
    // which in turn would keep it held off — a deadlock that never lets the
    // 68k reach fast RAM. Only a master that genuinely cannot have the bus
    // right now is stalled.
    // During the stale-beat quarantine a read-requesting master is held in
    // waitrequest: its level-held command must neither reach the slave nor
    // appear accepted (dropping s_read alone would let ~waitrequest clear
    // the master's command register as if the burst had started).
    assign m0_waitrequest = (m0_read && rd_hold)  ? 1'b1
                          : (busy && owner == M1) ? 1'b1          // m1 mid-burst
                                                  : s_waitrequest;

    assign m1_waitrequest = (m1_read && rd_hold)  ? 1'b1
                          : (busy && owner == M1) ? s_waitrequest // m1 owns it
                          : (busy || m0_req)      ? 1'b1          // m0 owns or wants it
                                                  : s_waitrequest;

    assign m0_readdata       = s_readdata;
    assign m1_readdata       = s_readdata;
    assign m0_readdatavalid  = s_readdatavalid && !stale_swallow && (rd_owner == M0);
    assign m1_readdatavalid  = s_readdatavalid && !stale_swallow && (rd_owner == M1);

endmodule
