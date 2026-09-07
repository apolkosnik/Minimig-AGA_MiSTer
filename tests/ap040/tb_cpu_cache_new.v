//--------------------------------------------------------------------------//
// cpu_cache_new external-cache control regression                          //
//                                                                          //
// Verifies independent I/D enables, that a hit in the wrong bank cannot    //
// satisfy a read, disabled banks do not fill, and a maintenance toggle is   //
// retained long enough to clear both tag RAMs.                              //
//                                                                          //
// A second instance carries CACHE_ENABLE(0) -- the configuration the        //
// Minimig build now ships, where ap040_cache is the only cache and this     //
// module is reduced to pass-through.  It has no storage to poke, so it is   //
// driven through its ports alone and held to the contract that matters      //
// there: every read goes to memory, no read is ever answered from a tag,    //
// and a re-read after memory changes returns the NEW value.                 //
//--------------------------------------------------------------------------//

`timescale 1ns/1ps

module tb_cpu_cache_new;
	reg clk = 0;
	reg rst = 1;
	always #5 clk = ~clk;

	reg  [3:0]  cpu_cache_ctrl = 0;
	reg         cache_inhibit = 0;
	reg         cpu_cs = 0;
	reg [28:1]  cpu_adr = 0;
	reg  [1:0]  cpu_bs = 2'b11;
	reg         cpu_we = 0;
	reg         cpu_ir = 0;
	reg         cpu_dr = 0;
	reg [15:0]  cpu_dat_w = 0;
	wire [15:0] cpu_dat_r;
	wire        cpu_ack;
	wire        wb_en;
	reg [15:0]  sdr_dat_r = 16'hA55A;
	wire        sdr_read_req;
	reg         sdr_read_ack = 0;
	reg         snoop_act = 0;
	reg [28:1]  snoop_adr = 0;
	reg [15:0]  snoop_dat_w = 0;
	reg  [1:0]  snoop_bs = 0;

	integer errors = 0;
	integer timeout;
	integer mem_index;
	reg [17:0] tag;
	reg [17:0] vtag;        // victim line's tag, for the resurrection check
	reg  [7:0] index;
	reg  [1:0] block;
	reg        saw_req;

	cpu_cache_new dut (
		.clk(clk), .rst(rst), .cpu_cache_ctrl(cpu_cache_ctrl),
		.cache_inhibit(cache_inhibit), .cpu_cs(cpu_cs), .cpu_adr(cpu_adr),
		.cpu_bs(cpu_bs), .cpu_we(cpu_we), .cpu_ir(cpu_ir), .cpu_dr(cpu_dr),
		.cpu_dat_w(cpu_dat_w), .cpu_dat_r(cpu_dat_r), .cpu_ack(cpu_ack),
		.wb_en(wb_en), .sdr_dat_r(sdr_dat_r), .sdr_read_req(sdr_read_req),
		.sdr_read_ack(sdr_read_ack), .snoop_act(snoop_act),
		.snoop_adr(snoop_adr), .snoop_dat_w(snoop_dat_w), .snoop_bs(snoop_bs)
	);

	// The shipping configuration.  Its own stimulus throughout: sharing the
	// enabled instance's signals would run two state machines off one set of
	// acknowledges and prove nothing about either.
	reg  [3:0]  nx_cache_ctrl = 4'b0011;   // both banks enabled, and ignored
	reg         nx_cpu_cs = 0;
	reg [28:1]  nx_cpu_adr = 0;
	reg         nx_cpu_we = 0;
	reg         nx_cpu_ir = 0;
	reg         nx_cpu_dr = 0;
	reg [15:0]  nx_cpu_dat_w = 0;
	wire [15:0] nx_cpu_dat_r;
	wire        nx_cpu_ack;
	wire        nx_wb_en;
	reg [15:0]  nx_sdr_dat_r = 0;
	wire        nx_sdr_read_req;
	reg         nx_sdr_read_ack = 0;

	cpu_cache_new #(.CACHE_ENABLE(0)) dut_nx (
		.clk(clk), .rst(rst), .cpu_cache_ctrl(nx_cache_ctrl),
		.cache_inhibit(1'b0), .cpu_cs(nx_cpu_cs), .cpu_adr(nx_cpu_adr),
		.cpu_bs(2'b11), .cpu_we(nx_cpu_we), .cpu_ir(nx_cpu_ir),
		.cpu_dr(nx_cpu_dr), .cpu_dat_w(nx_cpu_dat_w),
		.cpu_dat_r(nx_cpu_dat_r), .cpu_ack(nx_cpu_ack), .wb_en(nx_wb_en),
		.sdr_dat_r(nx_sdr_dat_r), .sdr_read_req(nx_sdr_read_req),
		.sdr_read_ack(nx_sdr_read_ack), .snoop_act(1'b0), .snoop_adr(28'd0),
		.snoop_dat_w(16'd0), .snoop_bs(2'b00)
	);

	task wait_idle;
		begin
			timeout = 0;
			while ((dut.cpu_sm_state != 4'd1 || dut.sdr_sm_state != 4'd2) &&
			       timeout < 1000) begin
				@(posedge clk);
				timeout = timeout + 1;
			end
			if (timeout == 1000) begin
				$display("FAIL: cache did not become idle");
				errors = errors + 1;
			end
		end
	endtask

	task install_i_line;
		input [15:0] value;
		begin
			tag = cpu_adr[28:11];
			index = cpu_adr[10:3];
			block = cpu_adr[2:1];
			mem_index = {index, block};
			dut.g_storage.itram.mem[index] = (40'h1 << 38) | tag;
			dut.g_storage.idram0.ram_l.mem[mem_index] = value[7:0];
			dut.g_storage.idram0.ram_u.mem[mem_index] = value[15:8];
		end
	endtask

	task install_d_line;
		input [15:0] value;
		begin
			tag = cpu_adr[28:11];
			index = cpu_adr[10:3];
			block = cpu_adr[2:1];
			mem_index = {index, block};
			dut.g_storage.dtram.mem[index] = (40'h1 << 38) | tag;
			dut.g_storage.ddram0.ram_l.mem[mem_index] = value[7:0];
			dut.g_storage.ddram0.ram_u.mem[mem_index] = value[15:8];
		end
	endtask

	task cached_read;
		input instr;
		input [15:0] expected;
		begin
			cpu_ir = instr;
			cpu_dr = !instr;
			cpu_cs = 1;
			saw_req = 0;
			timeout = 0;
			while (!cpu_ack && timeout < 20) begin
				@(posedge clk);
				if (sdr_read_req) saw_req = 1;
				timeout = timeout + 1;
			end
			if (!cpu_ack || saw_req || cpu_dat_r !== expected) begin
				$display("FAIL: %s cache hit ack=%b req=%b data=%h expected=%h",
				         instr ? "instruction" : "data", cpu_ack, saw_req,
				         cpu_dat_r, expected);
				errors = errors + 1;
			end
			cpu_cs = 0;
			cpu_ir = 0;
			cpu_dr = 0;
			repeat (3) @(posedge clk);
		end
	endtask

	// Finish a line fill the previous test left half-serviced: cpu_ack
	// arrives on the first word, but the fill keeps requesting the rest
	// of the line, so both state machines stay busy until those are
	// acked.  Pump acks until the cache is genuinely idle.
	task drain_fill;
		begin
			// FILL2..FILL4 do not re-request: the controller streams the
			// rest of the line, so the ack must be driven unconditionally
			timeout = 0;
			while ((dut.cpu_sm_state != 4'd1 || dut.sdr_sm_state != 4'd2) &&
			       timeout < 500) begin
				@(posedge clk);
				sdr_read_ack = 1;
				timeout = timeout + 1;
			end
			sdr_read_ack = 0;
			repeat (3) @(posedge clk);
		end
	endtask

	// A cache-inhibited read must go to memory and return what memory
	// holds NOW -- never the cached copy of the same physical address.
	task inhibited_read;
		input instr;
		input [15:0] fresh;
		begin
			cpu_ir = instr;
			cpu_dr = !instr;
			cpu_cs = 1;
			timeout = 0;
			while (!sdr_read_req && timeout < 20) begin
				@(posedge clk);
				timeout = timeout + 1;
			end
			if (!sdr_read_req) begin
				$display("FAIL: cache-inhibited %s read was served from the cache",
				         instr ? "instruction" : "data");
				errors = errors + 1;
			end
			sdr_dat_r = fresh;
			// BOTH shipped controllers answer a cache_req with a WHOLE
			// LINE -- ddram_ctrl states 1..4, sdram_ctrl slots
			// 8/10/12/14 -- whether or not the cache allocates it.
			// Driving a single beat modelled hardware that does not
			// exist, and hid the stranded-beat corruption below.
			repeat (4) begin
				sdr_read_ack = 1;
				@(posedge clk);
			end
			sdr_read_ack = 0;
			timeout = 0;
			while (!cpu_ack && timeout < 20) begin
				@(posedge clk);
				timeout = timeout + 1;
			end
			if (cpu_dat_r !== fresh) begin
				$display("FAIL: cache-inhibited %s read returned %h, memory holds %h",
				         instr ? "instruction" : "data", cpu_dat_r, fresh);
				errors = errors + 1;
			end
			cpu_cs = 0;
			cpu_ir = 0;
			cpu_dr = 0;
			repeat (3) @(posedge clk);
		end
	endtask

	task uncached_read;
		input instr;
		begin
			cpu_ir = instr;
			cpu_dr = !instr;
			cpu_cs = 1;
			timeout = 0;
			while (!sdr_read_req && timeout < 20) begin
				@(posedge clk);
				timeout = timeout + 1;
			end
			if (!sdr_read_req) begin
				$display("FAIL: %s read was incorrectly satisfied by other cache bank",
				         instr ? "instruction" : "data");
				errors = errors + 1;
			end
			// The selected bank is disabled, so one returned word must complete
			// without starting a four-word line fill.
			// BOTH shipped controllers answer a cache_req with a WHOLE
			// LINE -- ddram_ctrl states 1..4, sdram_ctrl slots
			// 8/10/12/14 -- whether or not the cache allocates it.
			// Driving a single beat modelled hardware that does not
			// exist, and hid the stranded-beat corruption below.
			repeat (4) begin
				sdr_read_ack = 1;
				@(posedge clk);
			end
			sdr_read_ack = 0;
			cpu_cs = 0;
			cpu_ir = 0;
			cpu_dr = 0;
			repeat (3) @(posedge clk);
		end
	endtask

	// ---- pass-through instance (CACHE_ENABLE=0) ----------------------
	//
	// The only read path left is CPU_SM_READ's miss branch: it raises
	// sdr_read_req, and FILL1 takes the FIRST acknowledged word as the
	// CPU's data before jumping straight to FILLW without allocating.
	// Both controllers answer with a whole line regardless, so the task
	// drives four beats and poisons beats 2..4 -- taking any of them
	// would be the stranded-beat mis-selection, and it must not happen.
	integer nx_timeout;
	reg     nx_saw_req;

	task nx_read;
		input instr;
		input [15:0] expected;
		begin
			nx_cpu_ir = instr;
			nx_cpu_dr = !instr;
			nx_sdr_dat_r = expected;
			nx_cpu_cs = 1;
			nx_saw_req = 0;
			nx_timeout = 0;
			while (!nx_sdr_read_req && nx_timeout < 20) begin
				@(posedge clk);
				nx_timeout = nx_timeout + 1;
			end
			if (!nx_sdr_read_req) begin
				$display("FAIL: pass-through %s read never reached memory (ack=%b data=%h)",
				         instr ? "instruction" : "data", nx_cpu_ack, nx_cpu_dat_r);
				errors = errors + 1;
			end
			else nx_saw_req = 1;
			// beat 1 carries the answer; the rest of the line is poison
			nx_sdr_read_ack = 1;
			@(posedge clk);
			nx_sdr_dat_r = 16'hBAD0;
			repeat (3) @(posedge clk);
			nx_sdr_read_ack = 0;
			nx_timeout = 0;
			while (!nx_cpu_ack && nx_timeout < 20) begin
				@(posedge clk);
				nx_timeout = nx_timeout + 1;
			end
			if (!nx_cpu_ack) begin
				$display("FAIL: pass-through %s read never acknowledged",
				         instr ? "instruction" : "data");
				errors = errors + 1;
			end
			else if (nx_cpu_dat_r !== expected) begin
				$display("FAIL: pass-through %s read returned %h, memory held %h",
				         instr ? "instruction" : "data", nx_cpu_dat_r, expected);
				errors = errors + 1;
			end
			nx_cpu_cs = 0;
			nx_cpu_ir = 0;
			nx_cpu_dr = 0;
			repeat (4) @(posedge clk);
		end
	endtask

	task nx_write;
		input [15:0] value;
		begin
			nx_cpu_dat_w = value;
			nx_cpu_we = 1;
			nx_cpu_cs = 1;
			nx_timeout = 0;
			while (!nx_wb_en && nx_timeout < 20) begin
				@(posedge clk);
				nx_timeout = nx_timeout + 1;
			end
			if (!nx_wb_en) begin
				$display("FAIL: pass-through write did not enable the write buffer");
				errors = errors + 1;
			end
			nx_cpu_cs = 0;
			nx_cpu_we = 0;
			repeat (4) @(posedge clk);
			if (dut_nx.cpu_sm_state !== 4'd1) begin
				$display("FAIL: pass-through write left the CPU state machine at %0d",
				         dut_nx.cpu_sm_state);
				errors = errors + 1;
			end
		end
	endtask

	initial begin
		repeat (5) @(posedge clk);
		rst = 0;
		wait_idle;

		cpu_adr = 28'h0012340;

		// I enabled, D disabled: only the instruction view may hit.
		cpu_cache_ctrl = 4'b0001;
		repeat (3) @(posedge clk);
		install_i_line(16'h1234);
		repeat (2) @(posedge clk);
		cached_read(1'b1, 16'h1234);
		uncached_read(1'b0);
		if (dut.g_storage.dtram.mem[index][38]) begin
			$display("FAIL: disabled data cache filled a tag");
			errors = errors + 1;
		end

		// D enabled, I disabled: the mirror-image case.
		cpu_cache_ctrl = 4'b0010;
		repeat (3) @(posedge clk);
		install_d_line(16'h5678);
		repeat (2) @(posedge clk);
		cached_read(1'b0, 16'h5678);
		uncached_read(1'b1);

		// Reinstall a valid line, then toggle maintenance while idle.  Both
		// tag memories must be cleared and both state machines must finish.
		cpu_cache_ctrl[1:0] = 2'b11;
		repeat (3) @(posedge clk);
		install_i_line(16'h9ABC);
		install_d_line(16'hDEF0);
		cpu_cache_ctrl[3] = ~cpu_cache_ctrl[3];
		timeout = 0;
		while (!dut.cc_clear_pending && timeout < 20) begin
			@(posedge clk);
			timeout = timeout + 1;
		end
		if (!dut.cc_clear_pending) begin
			$display("FAIL: maintenance toggle was not captured");
			errors = errors + 1;
		end
		// Let the accepting edge move both machines out of idle before
		// waiting for the completed invalidation pass.
		repeat (2) @(posedge clk);
		wait_idle;
		index = cpu_adr[10:3];
		if (dut.g_storage.itram.mem[index][38:37] != 0 ||
		    dut.g_storage.dtram.mem[index][38:37] != 0) begin
			$display("FAIL: maintenance toggle did not invalidate both caches");
			errors = errors + 1;
		end

		// A maintenance clear whose background sweep passes the miss index
		// while a line fill is waiting for SDRAM must not be undone by the
		// fill's tag writeback.  The writeback composes the OTHER way's
		// tag and valid bit from the tag row it read, so that read has to
		// reflect the sweep: a row snapshot taken at the miss decision
		// restores valid bits the sweep cleared and resurrects flushed
		// lines with stale data underneath them.
		//
		// Set the victim in way1 and leave the row's LRU bit selecting
		// way0, so the fill goes to way0 and way1 is carried across the
		// writeback purely from the tag-row read under test.
		cpu_cache_ctrl[1:0] = 2'b11;
		repeat (3) @(posedge clk);
		cpu_adr = 28'h0012340;
		tag   = cpu_adr[28:11];
		index = cpu_adr[10:3];
		block = cpu_adr[2:1];
		mem_index = {index, block};
		dut.g_storage.dtram.mem[index] = (40'h1 << 39)          // LRU: fill takes way0
		                     | (40'h1 << 37)          // way1 valid
		                     | ({22'd0, tag} << 18);  // way1 tag
		vtag = tag;
		dut.g_storage.ddram1.ram_l.mem[mem_index] = 8'h0D;
		dut.g_storage.ddram1.ram_u.mem[mem_index] = 8'hD0;
		cached_read(0, 16'hD00D);	// sanity: way1 hits before the clear

		cpu_adr = 28'h1012340;	// same index, different tag: must miss
		cpu_ir = 0;
		cpu_dr = 1;
		cpu_cs = 1;
		timeout = 0;
		while (!sdr_read_req && timeout < 20) begin
			@(posedge clk);
			timeout = timeout + 1;
		end
		if (!sdr_read_req) begin
			$display("FAIL: clear-during-fill test did not miss");
			errors = errors + 1;
		end
		// the fill is now pending: run a full maintenance sweep before
		// acknowledging it, exactly as CacheClearU does under load
		cpu_cache_ctrl[3] = ~cpu_cache_ctrl[3];
		timeout = 0;
		while (dut.cache_init_done && timeout < 20) begin
			@(posedge clk);
			timeout = timeout + 1;
		end
		timeout = 0;
		while (!dut.cache_init_done && timeout < 2000) begin
			@(posedge clk);
			timeout = timeout + 1;
		end
		if (!dut.cache_init_done) begin
			$display("FAIL: maintenance sweep did not finish during fill wait");
			errors = errors + 1;
		end
		// Complete the fill just after a sweep pass has walked past this
		// row.  The clear stays pending until the CPU side accepts it (only
		// possible once the fill retires), so the SDR side keeps re-sweeping
		// -- a writeback landing mid-pass is wiped by the next pass.  The
		// reachable window is the FINAL pass: the CPU retires the fill, the
		// pending clear is then accepted by both sides and stops, and any
		// bits the writeback restored after the pass swept this row survive
		// with stale data under them.
		timeout = 0;
		while (!(dut.sdr_sm_state == 4'd1 && dut.sdr_sm_adr[9:2] > 8'd220 &&
		         dut.sdr_sm_adr[9:2] < 8'd248) && timeout < 4000) begin
			@(posedge clk);
			timeout = timeout + 1;
		end
		sdr_dat_r = 16'hF111;
		sdr_read_ack = 1;
		timeout = 0;
		while (!cpu_ack && timeout < 20) begin
			@(posedge clk);
			timeout = timeout + 1;
		end
		repeat (4) @(posedge clk);
		sdr_read_ack = 0;
		cpu_cs = 0;
		cpu_dr = 0;
		repeat (2) @(posedge clk);
		wait_idle;
		// the swept victim must not be valid in EITHER way: the fill may
		// validate only its own way, with its own tag
		index = cpu_adr[10:3];
		if ((dut.g_storage.dtram.mem[index][38] && dut.g_storage.dtram.mem[index][17: 0] == vtag) ||
		    (dut.g_storage.dtram.mem[index][37] && dut.g_storage.dtram.mem[index][35:18] == vtag)) begin
			$display("FAIL: fill writeback resurrected the swept victim line (tagrow=%h)",
			         dut.g_storage.dtram.mem[index]);
			errors = errors + 1;
		end
		// and the architectural consequence: the old address must miss
		cpu_adr = 28'h0012340;
		cpu_ir = 0;
		cpu_dr = 1;
		cpu_cs = 1;
		saw_req = 0;
		timeout = 0;
		while (!cpu_ack && timeout < 30) begin
			@(posedge clk);
			if (sdr_read_req) begin
				saw_req = 1;
				sdr_dat_r = 16'hF222;
				sdr_read_ack = 1;
			end
			timeout = timeout + 1;
		end
		sdr_read_ack = 0;
		cpu_cs = 0;
		cpu_dr = 0;
		if (!saw_req) begin
			$display("FAIL: stale line survived the clear (read hit, data=%h)",
			         cpu_dat_r);
			errors = errors + 1;
		end
		repeat (3) @(posedge clk);

		// ---- CACHE_ENABLE(0): the shipping pass-through ------------------
		// No storage exists, so the nostorage branch must tie every tag and
		// data read to zero -- that is what makes the valid bits read as 0
		// and every hit path unreachable.
		if (dut_nx.itram_cpu_dat_r !== 40'd0 || dut_nx.dtram_cpu_dat_r !== 40'd0 ||
		    dut_nx.idram0_cpu_dat_r !== 16'd0 || dut_nx.ddram0_cpu_dat_r !== 16'd0 ||
		    dut_nx.idram1_cpu_dat_r !== 16'd0 || dut_nx.ddram1_cpu_dat_r !== 16'd0) begin
			$display("FAIL: CACHE_ENABLE(0) left storage outputs undriven");
			errors = errors + 1;
		end

		nx_cpu_adr = 28'h0012340;
		// Same address twice with memory changed underneath.  With storage
		// the second read would hit and return the first value; without it,
		// every read must reach memory and see the new one.  Instruction and
		// data views are checked separately: they are separate banks, and
		// only cpu_cache_enable/_d being forced low disables both.
		nx_read(1'b1, 16'h1111);
		nx_read(1'b1, 16'h2222);
		nx_read(1'b0, 16'h3333);
		nx_read(1'b0, 16'h4444);

		// A write still has to drive the write buffer and retire; nothing
		// about the write path depends on the tags being present.
		nx_write(16'h5555);

		// The maintenance toggle re-runs the init sweep, which is state
		// machine work with no storage behind it.  It must still complete,
		// or the first CINV after boot parks the CPU state machine in INIT
		// forever.
		nx_cache_ctrl[3] = ~nx_cache_ctrl[3];
		nx_timeout = 0;
		while (!dut_nx.cache_init_done && nx_timeout < 20) begin
			@(posedge clk);
			nx_timeout = nx_timeout + 1;
		end
		nx_timeout = 0;
		while (dut_nx.cache_init_done && nx_timeout < 100) begin
			@(posedge clk);
			nx_timeout = nx_timeout + 1;
		end
		nx_timeout = 0;
		while (!dut_nx.cache_init_done && nx_timeout < 2000) begin
			@(posedge clk);
			nx_timeout = nx_timeout + 1;
		end
		if (!dut_nx.cache_init_done) begin
			$display("FAIL: CACHE_ENABLE(0) maintenance sweep never completed");
			errors = errors + 1;
		end
		nx_read(1'b0, 16'h6666);

		if (errors == 0) $display("ALL TESTS PASSED");
		else             $display("TEST FAILED with %0d errors", errors);
		$finish;
	end
endmodule

// Simple synchronous dual-port RAM model for cpu_cache_new's generic dpram.
module dpram #(parameter AW = 8, parameter DW = 8) (
	input clock,
	input [AW-1:0] address_a,
	input [DW-1:0] data_a,
	input wren_a,
	output reg [DW-1:0] q_a,
	input [AW-1:0] address_b,
	input [DW-1:0] data_b,
	input wren_b,
	output reg [DW-1:0] q_b
);
	reg [DW-1:0] mem [0:(1<<AW)-1];
	always @(posedge clock) begin
		if (wren_a) mem[address_a] <= data_a;
		if (wren_b) mem[address_b] <= data_b;
		q_a <= mem[address_a];
		q_b <= mem[address_b];
	end
endmodule
