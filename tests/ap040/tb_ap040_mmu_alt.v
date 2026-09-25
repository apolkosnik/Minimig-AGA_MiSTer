// ap040_mmu.v's function codes (caches stage A2), through its public ports.
// MC68040UM 3.2, Table 3-2: MOVES to an alternate address space -- FC 0, 3,
// 4 or 7 -- is "immediately used as a physical address without
// translation": no ATC lookup, no table search, no protection, no fault;
// and an alternate-space access asserts CIOUT (7.x, write transfer timing),
// so it is never cached. MOVES to FC 2 or 6 is a data reference in 1 or 5:
// translated through the data ATC, and on the bus as data. Translation is
// on throughout (TC.E, 4K pages; tables at $1000/$2000/$3000); pages 4 and
// 7 map to $A000 and $B000, page 5 is invalid, and DTT0 write-protects the
// low 16 MB, so a translated write anywhere there would fault.
//   1. FC 0/3/4/7 data reads and writes, to a mapped page, an invalid one
//      and under DTT0's write protection: passed at their own address,
//      cache-inhibited, no walk, no fault.
//   2. FC 2/6 data: translated through the tables (a walk), on the bus as
//      FC 1/5; an instruction fetch in FC 2 keeps FC 2.
//   3. A control: FC 1 data is translated (walks), cacheable.
// Repeat with CE_DIV=4, the walker clock-enabled one clock in four.
`timescale 1ns/1ps
module tb_ap040_mmu_alt;
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

// One access; its result as the downstream port saw it when it passed.
reg [31:0] got_addr;
reg  [2:0] got_fc;
reg        got_nc, got_flt;
integer    got_walks;
task access;
    input [31:0] addr;
    input  [2:0] fc;
    input        instr, write_en;
    integer timeout, w0;
    begin
        @(negedge clk);
        w0 = walks;
        c_addr = addr; c_fc = fc; c_instr = instr; c_write = write_en; c_req = 1;
        #1;
        timeout = 0;
        while (!(ce && (c_ack || c_flt)) && timeout < 4000) begin
            @(negedge clk); #1; timeout = timeout + 1;
        end
        check(timeout < 4000, "request timed out");
        got_addr = m_addr; got_fc = m_fc; got_nc = m_nocache; got_flt = c_flt;
        @(posedge clk); #1;
        got_walks = walks - w0;
        idle;
    end
endtask

task alt_case;
    input [31:0] addr;
    input  [2:0] fc;
    input        write_en;
    input [511:0] label;
    begin
        access(addr, fc, 1'b0, write_en);
        check(!got_flt,            label);
        check(got_addr == addr,    label);
        check(got_nc,              label);
        check(got_walks == 0,      label);
        check(got_fc == fc,        label);
    end
endtask

integer k;
reg [2:0] alt_fc [0:3];
initial begin
    for (i = 0; i < 32; i = i + 1) pages[i] = (i << 12) | 3;
    pages[4] = 32'ha003;
    pages[5] = 32'h0;            // invalid
    pages[7] = 32'hb003;
    alt_fc[0] = 3'd0; alt_fc[1] = 3'd3; alt_fc[2] = 3'd4; alt_fc[3] = 3'd7;
    repeat (8) @(negedge clk);
    nreset = 1;
    idle;

    // 1. the alternate spaces, reads and writes
    for (k = 0; k < 4; k = k + 1) begin
        alt_case(32'h4010, alt_fc[k], 1'b0, "1: an alternate-space read of a mapped page was translated, cached, walked or faulted");
        alt_case(32'h5010, alt_fc[k], 1'b0, "1: an alternate-space read of an invalid page was not passed untranslated");
        alt_case(32'h5020, alt_fc[k], 1'b1, "1: an alternate-space write to an invalid page was not passed untranslated");
    end
    dtt0 = 32'h0000_C004;        // $00xxxxxx, either mode, write-protected
    for (k = 0; k < 4; k = k + 1)
        alt_case(32'h6010, alt_fc[k], 1'b1, "1: an alternate-space write was refused by a write-protecting TTR");
    // ...where the same TTR refuses an ordinary data write
    access(32'h6010, 3'd5, 1'b0, 1'b1);
    check(got_flt, "1: control: the write-protecting TTR did not refuse a data write");
    dtt0 = 0;

    // 2. program space as data
    access(32'h4030, 3'd2, 1'b0, 1'b0);
    check(!got_flt && got_addr == 32'ha030, "2: an FC 2 data read was not translated through the tables");
    check(got_fc == 3'd1, "2: an FC 2 data read did not go out as FC 1");
    access(32'h7030, 3'd6, 1'b0, 1'b0);
    check(!got_flt && got_addr == 32'hb030, "2: an FC 6 data read was not translated through the tables");
    check(got_fc == 3'd5, "2: an FC 6 data read did not go out as FC 5");
    check(!got_nc, "2: an FC 6 data read was cache-inhibited");
    access(32'h7040, 3'd2, 1'b1, 1'b0);
    check(!got_flt && got_addr == 32'hb040, "2: an FC 2 instruction fetch was not translated");
    check(got_fc == 3'd2, "2: an instruction fetch did not keep FC 2");

    // 3. the control: user data is translated, and walks for a new page
    access(32'h8010, 3'd1, 1'b0, 1'b0);
    check(!got_flt && got_addr == 32'h8010 && got_walks > 0, "3: an FC 1 data read of a new page did not walk");
    check(!got_nc, "3: an FC 1 data read was cache-inhibited");

    if (errors == 0) $display("ALL TESTS PASSED");
    else $display("%0d CHECK(S) FAILED", errors);
    $finish;
end
initial begin
    #(2000000 * CE_DIV);
    $display("FAIL: timed out");
    $finish;
end
endmodule
