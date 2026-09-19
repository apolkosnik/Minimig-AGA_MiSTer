// Exercise the last-hit copies through the MMU's public interfaces. Every
// request has an idle gap, so synchronous lookup alone cannot pass the
// immediate-hit checks. Repeat with CE_DIV=4 to exercise free-running RAM
// reads and maintenance while the walker is clock-enabled intermittently.
`timescale 1ns/1ps
module tb_ap040_atc_reuse;
parameter CE_DIV = 1;
reg clk = 0;
always #5 clk = ~clk;
reg nreset = 0;
integer clocks = 0;
always @(negedge clk) clocks = clocks + 1;
wire ce = (clocks % CE_DIV) == 0;
reg [31:0] tc = 32'h8000;
reg [31:0] urp = 32'h1000, srp = 32'h1000;
reg [31:0] itt0 = 0, itt1 = 0, dtt0 = 0, dtt1 = 0;
reg c_req = 0, c_write = 0, c_instr = 0;
reg [1:0] c_size = 2;
reg [31:0] c_addr = 0, c_wdata = 0;
reg [2:0] c_fc = 5;
wire c_ack, c_flt;
wire [31:0] c_rdata;
reg pt_req = 0, pt_write = 0, pt_access = 0;
reg [31:0] pt_addr = 0;
reg [2:0] pt_fc = 5;
wire pt_done;
wire [31:0] pt_mmusr;
reg pf_req = 0;
reg [1:0] pf_mode = 3;
reg [31:0] pf_addr = 0;
reg [2:0] pf_fc = 5;
wire pf_done;
wire m_req, m_write, m_instr, m_nocache;
wire [1:0] m_size;
wire [31:0] m_addr, m_wdata;
wire [2:0] m_fc;
wire m_ack = m_req;
wire [31:0] m_rdata = m_addr;
wire walker_req, walker_we;
wire [31:0] walker_addr, walker_wdat;
wire walker_ack = walker_req;
reg [31:0] walker_data;
wire walker_berr = 0;
wire [31:0] phys_addr;
wire cache_inhibit;
reg [31:0] pages [0:31];
integer walks = 0, errors = 0, i;
ap040_mmu dut (.*);

always @* begin
    case (walker_addr)
        32'h1000: walker_data = 32'h2003;
        32'h2000: walker_data = 32'h3003;
        default: walker_data = pages[walker_addr[6:2]];
    endcase
end
always @(posedge clk) if (nreset && ce && walker_req) begin
    walks <= walks + 1;
    if (walker_we && walker_addr[31:8] == 24'h000030)
        pages[walker_addr[6:2]] <= walker_wdat;
end

task check;
    input ok;
    input [511:0] label;
    begin
        if (!ok) begin errors = errors + 1; $display("FAIL: %0s", label); end
    end
endtask
task idle;
    begin
        @(negedge clk); c_req = 0;
        repeat (8*CE_DIV) @(negedge clk);
    end
endtask
task access_page;
    input [31:0] addr, expected;
    input instr, write_en, user_mode, fault, immediate;
    integer timeout;
    begin
        @(negedge clk);
        c_addr = addr; c_req = 1; c_write = write_en; c_instr = instr;
        c_fc = {~user_mode, instr ? 2'b10 : 2'b01};
        #1;
        if (immediate) check(m_req && m_addr == expected, "last-hit lookup did not bypass the RAM latency");
        timeout = 0;
        while (!(ce && (c_ack || c_flt)) && timeout < 4000) begin
            @(negedge clk); #1; timeout = timeout + 1;
        end
        check(timeout < 4000, "request timed out");
        check(c_flt == fault && c_ack == !fault, "wrong translation/fault result");
        if (!fault) check(m_addr == expected, "wrong physical address");
        // Sample the result on an enabled edge, then release the request.
        @(posedge clk); #1;
        idle;
    end
endtask
task flush_page;
    input [31:0] addr;
    integer timeout;
    begin
        @(negedge clk); pf_addr = addr; pf_mode = 1; pf_req = 1;
        timeout = 0;
        while (!pf_done && timeout < 4000) begin
            @(negedge clk); timeout = timeout + 1;
        end
        check(timeout < 4000, "PFLUSH timed out");
        pf_req = 0;
        idle;
    end
endtask
integer old_walks;
initial begin
    for (i = 0; i < 32; i = i + 1) pages[i] = (i << 12) | 3;
    pages[4] = 32'ha003;
    repeat (8) @(negedge clk);
    nreset = 1;
    idle;
    access_page('h4010, 'ha010, 0, 0, 0, 0, 0);
    old_walks = walks;
    access_page('h4040, 'ha040, 0, 0, 0, 0, 1);
    check(walks == old_walks, "a copied hit walked again");

    // A new I-ATC fill invalidates both copies; repopulate each by hitting
    // its real ATC entry, then alternate spaces without losing either copy.
    access_page('h4010, 'ha010, 1, 0, 0, 0, 0);
    access_page('h4010, 'ha010, 0, 0, 0, 0, 0);
    access_page('h4040, 'ha040, 1, 0, 0, 0, 1);
    access_page('h4044, 'ha044, 0, 0, 0, 0, 1);

    // A clean cached entry must walk before a WRITE to set its M bit.
    old_walks = walks;
    access_page('h4010, 'ha010, 0, 1, 0, 0, 0);
    check(walks > old_walks && pages[4][4], "write bypassed the M-bit update");
    access_page('h4040, 'ha040, 0, 1, 0, 0, 1);

    // Replacement after a page-specific sweep must discard the old copy.
    @(negedge clk); pages[4] = 32'hb003;
    flush_page('h4000);
    access_page('h4010, 'hb010, 0, 0, 0, 0, 0);
    access_page('h4040, 'hb040, 0, 0, 0, 0, 1);

    // Permissions and cache mode are part of the copied entry.
    @(negedge clk); pages[4] = 32'hb047; // write-protected, cache-inhibited
    flush_page('h4000);
    access_page('h4010, 'hb010, 0, 0, 0, 0, 0);
    access_page('h4040, 'hb040, 0, 0, 0, 0, 1);
    check(cache_inhibit, "copy lost cache-inhibit attribute");
    access_page('h4010, 0, 0, 1, 0, 1, 0);

    // The supervisor tag cannot authorize a user access; a nonresident
    // copied entry must continue faulting even after memory is repaired.
    @(negedge clk); pages[4] = 32'hb083;
    flush_page('h4000);
    access_page('h4010, 'hb010, 0, 0, 0, 0, 0);
    access_page('h4010, 0, 0, 0, 1, 1, 0);
    @(negedge clk); pages[5] = 0;
    access_page('h5010, 0, 0, 0, 0, 1, 0);
    old_walks = walks;
    @(negedge clk); pages[5] = 32'hc003;
    access_page('h5010, 0, 0, 0, 0, 1, 0);
    check(walks == old_walks, "nonresident copy was treated as a miss");
    flush_page('h5000);
    access_page('h5010, 'hc010, 0, 0, 0, 0, 0);

    // Changing page size must not reuse a 4K verdict as an 8K mapping.
    @(negedge clk); tc = 'hc000; pages[2] = 'he003;
    access_page('h4010, 'he010, 0, 0, 0, 0, 0);
    access_page('h5010, 'hf010, 0, 0, 0, 0, 1);
    if (errors == 0) $display("ALL TESTS PASSED (ATC reuse, CE_DIV=%0d)", CE_DIV);
    else $fatal(1, "TEST FAILED: %0d checks", errors);
    $finish;
end
endmodule
