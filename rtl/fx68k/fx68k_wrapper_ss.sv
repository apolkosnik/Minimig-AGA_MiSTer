//
// FX68K Wrapper with Superscalar Support
//
// This wrapper provides unified interface for both:
// - Original cycle-accurate FX68K core
// - New superscalar FX68K core
//
// Selection via fx68k_config.svh
//

`timescale 1 ns / 1 ns
`include "fx68k_config.svh"

module fx68k_wrapper_ss(
    input clk,
    input HALTn,
    input extReset,
    input pwrUp,
    input enPhi1, enPhi2,

    // Bus interface
    output eRWn,
    output ASn,
    output LDSn,
    output UDSn,
    output logic E,
    output VMAn,
    output FC0, FC1, FC2,
    output BGn,
    output oRESETn,
    output oHALTEDn,

    input DTACKn,
    input VPAn,
    input BERRn,
    input BRn,
    input BGACKn,
    input IPL0n, IPL1n, IPL2n,
    input [15:0] iEdb,
    output [15:0] oEdb,
    output [23:1] eab,

    // Superscalar status outputs (only valid in superscalar mode)
    output logic [31:0] ss_ipc,           // Instructions per cycle (fixed point)
    output logic [15:0] ss_rob_occupancy, // ROB occupancy percentage
    output logic [15:0] ss_iq_occupancy   // IQ occupancy percentage
);

`ifdef FX68K_SUPERSCALAR
    // ========================================================================
    // Superscalar Mode
    // ========================================================================

    logic [2:0] ipl_sync;
    logic [23:1] ss_addr;
    logic [15:0] ss_data_out, ss_data_in;
    logic ss_read_req, ss_write_req, ss_data_valid;
    logic ss_halted;
    logic [31:0] ss_pc;

    // Synchronize IPL
    always_ff @(posedge clk) begin
        if (extReset)
            ipl_sync <= 3'b111;
        else
            ipl_sync <= ~{IPL2n, IPL1n, IPL0n};
    end

    // Instantiate superscalar core
    fx68k_superscalar ss_core (
        .clk(clk),
        .reset(extReset | pwrUp),
        .addr(ss_addr),
        .data_out(ss_data_out),
        .data_in(ss_data_in),
        .read_req(ss_read_req),
        .write_req(ss_write_req),
        .data_valid(ss_data_valid),
        .ipl(ipl_sync),
        .halted(ss_halted),
        .pc_out(ss_pc)
    );

    // Bus interface adapter
    // Converts superscalar interface to 68000 bus protocol
    fx68k_ss_bus_adapter bus_adapter (
        .clk(clk),
        .reset(extReset | pwrUp),

        // Superscalar core interface
        .ss_addr(ss_addr),
        .ss_data_out(ss_data_out),
        .ss_data_in(ss_data_in),
        .ss_read_req(ss_read_req),
        .ss_write_req(ss_write_req),
        .ss_data_valid(ss_data_valid),

        // 68000 bus interface
        .eRWn(eRWn),
        .ASn(ASn),
        .LDSn(LDSn),
        .UDSn(UDSn),
        .DTACKn(DTACKn),
        .VPAn(VPAn),
        .BERRn(BERRn),
        .iEdb(iEdb),
        .oEdb(oEdb),
        .eab(eab)
    );

    // Status outputs
    assign oHALTEDn = ~ss_halted;
    assign oRESETn = ~(extReset | pwrUp);

    // E clock generation (for compatibility)
    logic [3:0] e_counter;
    always_ff @(posedge clk) begin
        if (extReset | pwrUp) begin
            E <= 1'b0;
            e_counter <= 4'd0;
        end else begin
            e_counter <= e_counter + 1'b1;
            if (e_counter == 4'd9) begin
                e_counter <= 4'd0;
            end
            E <= (e_counter < 4'd5);
        end
    end

    assign VMAn = 1'b1;  // No VMA support in superscalar mode
    assign BGn = 1'b1;   // No DMA support in superscalar mode
    assign FC0 = 1'b1;
    assign FC1 = 1'b0;
    assign FC2 = ss_pc[24];  // Supervisor/User from PC

    // Performance monitoring
    `ifdef SS_PERF_COUNTERS
        logic [31:0] cycle_count;
        logic [31:0] inst_count;

        always_ff @(posedge clk) begin
            if (extReset | pwrUp) begin
                cycle_count <= 32'd0;
                inst_count <= 32'd0;
                ss_ipc <= 32'd0;
            end else begin
                cycle_count <= cycle_count + 1;
                // inst_count would be incremented by commit stage
                // IPC calculation (fixed point: 16.16)
                if (cycle_count[15:0] == 16'hFFFF) begin
                    ss_ipc <= (inst_count << 16) / cycle_count;
                end
            end
        end
    `else
        assign ss_ipc = 32'h0;
    `endif

    assign ss_rob_occupancy = 16'd0;  // TODO: Connect to ROB
    assign ss_iq_occupancy = 16'd0;   // TODO: Connect to IQ

`else
    // ========================================================================
    // Cycle-Accurate Mode (Original FX68K)
    // ========================================================================

    fx68k original_core (
        .clk(clk),
        .HALTn(HALTn),
        .extReset(extReset),
        .pwrUp(pwrUp),
        .enPhi1(enPhi1),
        .enPhi2(enPhi2),
        .eRWn(eRWn),
        .ASn(ASn),
        .LDSn(LDSn),
        .UDSn(UDSn),
        .E(E),
        .VMAn(VMAn),
        .FC0(FC0),
        .FC1(FC1),
        .FC2(FC2),
        .BGn(BGn),
        .oRESETn(oRESETn),
        .oHALTEDn(oHALTEDn),
        .DTACKn(DTACKn),
        .VPAn(VPAn),
        .BERRn(BERRn),
        .BRn(BRn),
        .BGACKn(BGACKn),
        .IPL0n(IPL0n),
        .IPL1n(IPL1n),
        .IPL2n(IPL2n),
        .iEdb(iEdb),
        .oEdb(oEdb),
        .eab(eab)
    );

    // Status outputs not available in cycle-accurate mode
    assign ss_ipc = 32'd0;
    assign ss_rob_occupancy = 16'd0;
    assign ss_iq_occupancy = 16'd0;

`endif

endmodule


// ============================================================================
// Bus Adapter (Superscalar <-> 68000 Bus)
// ============================================================================

`ifdef FX68K_SUPERSCALAR

module fx68k_ss_bus_adapter(
    input clk,
    input reset,

    // Superscalar core interface
    input [23:1] ss_addr,
    input [15:0] ss_data_out,
    output logic [15:0] ss_data_in,
    input ss_read_req,
    input ss_write_req,
    output logic ss_data_valid,

    // 68000 bus interface
    output logic eRWn,
    output logic ASn,
    output logic LDSn,
    output logic UDSn,
    input DTACKn,
    input VPAn,
    input BERRn,
    input [15:0] iEdb,
    output logic [15:0] oEdb,
    output logic [23:1] eab
);

    typedef enum logic [2:0] {
        IDLE,
        S0,
        S2,
        S4,
        S6,
        S7
    } bus_state_t;

    bus_state_t state;

    always_ff @(posedge clk) begin
        if (reset) begin
            state <= IDLE;
            ASn <= 1'b1;
            LDSn <= 1'b1;
            UDSn <= 1'b1;
            eRWn <= 1'b1;
            ss_data_valid <= 1'b0;
            eab <= 23'h0;
            oEdb <= 16'h0;
        end else begin
            case (state)
                IDLE: begin
                    ss_data_valid <= 1'b0;
                    if (ss_read_req || ss_write_req) begin
                        state <= S0;
                        eab <= ss_addr;
                        eRWn <= ~ss_write_req;
                        if (ss_write_req) begin
                            oEdb <= ss_data_out;
                        end
                    end
                end

                S0: begin
                    state <= S2;
                    ASn <= 1'b0;
                end

                S2: begin
                    state <= S4;
                    LDSn <= 1'b0;
                    UDSn <= 1'b0;
                end

                S4: begin
                    if (~DTACKn || ~VPAn) begin
                        state <= S6;
                        if (~eRWn) begin
                            ss_data_in <= iEdb;
                        end
                    end
                    // Wait for DTACK/VPA
                end

                S6: begin
                    state <= S7;
                    ss_data_valid <= 1'b1;
                end

                S7: begin
                    state <= IDLE;
                    ASn <= 1'b1;
                    LDSn <= 1'b1;
                    UDSn <= 1'b1;
                    eRWn <= 1'b1;
                end
            endcase
        end
    end

endmodule

`endif
