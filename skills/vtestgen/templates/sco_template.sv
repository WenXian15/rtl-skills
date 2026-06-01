//==============================================================================
// sco_{{IFACE}}.sv : CPU-controllable scoreboard for the {{IFACE}} data-plane output
//
// Architecture contract (every sco_*.sv must follow this):
//   * It is a CPU-bus SLAVE. It self-decodes its own address slice in SCO space
//     (base passed via parameter SCO_ADDR). The test script controls it with
//     cpu_write only and reads results with cpu_read/cpu_read_check.
//   * It TAPS a DUT data-plane output (it never drives the DUT) and checks each
//     accepted beat continuously against an expected value.
//   * Config registers (write):  ENA (start/stop checking), MODE, CLR (clear
//     counters), and the word-addressed expected payload EXP.
//   * Status registers (read) :  ERRCNT (mismatches), CHKCNT (beats checked),
//     and the word-addressed first-mismatch capture FM, via <name>_dout.
//   * On a mismatch it prints "[ERROR] ..." then "[FINISH] FAIL" and $finish
//     (self-fail, like cpu_read_check). ERRCNT is still exposed so a testcase
//     can instead defer the verdict with cpu_read_check(SCO_ERRCNT, 0).
//
// Expected-value source (default = OPTION 2): the expected payload is supplied
// over the CPU bus (written by the testcase, or mirrored from what the matching
// sti_* driver injected). Replace the COMPARE BODY for richer schemes.
//   OPTION 1 (escape hatch): build a reference model here that recomputes the
//   expected output from the observed inputs -- use only when the transform is
//   non-trivial. OPTION 3: replay expected beats from a file.
// Only the COMPARE BODY changes between projects; the CPU-slave wrapper stays.
//==============================================================================
`timescale 1ns/1ps

module sco_{{IFACE}} #(
    parameter SCO_ADDR = 20'hC000,   // this scoreboard's config/status base
    parameter DATA_W   = {{DATA_W}}
) (
    input  wire                 clk,
    input  wire                 rst_n,

    // cpu-bus slave (shared bus, broadcast from the bench)
    input  wire                 cpu_cs,
    input  wire                 cpu_we,
    input  wire                 cpu_oe,
    input  wire [19:0]          cpu_addr,
    input  wire [31:0]          cpu_din,
    output reg  [31:0]          cpu_dout,

    // data-plane output tap from the DUT (observe only - never driven here)
    input  wire                 in_valid,
    input  wire                 in_ready,        // tie to 1'b1 if the iface has no ready
    input  wire [DATA_W-1:0]    in_data
);

    // payload is word-addressed in 32-bit CPU words (matches the cpu bus width)
    localparam NW = (DATA_W + 31) / 32;

    // ----- config / status register addresses (offsets from SCO_ADDR) --------
    localparam REG_ENA    = SCO_ADDR + 0;        // [0] enable checking
    localparam REG_MODE   = SCO_ADDR + 1;        // pattern/mode select
    localparam REG_CLR    = SCO_ADDR + 2;        // write 1 -> clear counters
    localparam REG_ERRCNT = SCO_ADDR + 3;        // (ro) mismatch count
    localparam REG_CHKCNT = SCO_ADDR + 4;        // (ro) beats checked
    localparam SCO_EXP    = SCO_ADDR + 16;       // expected payload, word i at +i
    localparam SCO_FM     = SCO_ADDR + 16 + NW;  // first-mismatch capture, word i

    reg                  ena;
    reg [31:0]           mode;
    reg [31:0]           errcnt;
    reg [31:0]           chkcnt;
    reg [DATA_W-1:0]     exp;                    // expected payload (word-written)
    reg [DATA_W-1:0]     fm_data;                // first mismatched beat captured

    // ----- cpu-slave write decode --------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            ena <= 1'b0; mode <= 32'd0; exp <= '0;
        end else if (cpu_cs && cpu_we) begin
            if (cpu_addr == REG_ENA)  ena  <= cpu_din[0];
            if (cpu_addr == REG_MODE) mode <= cpu_din;
            // expected payload: word-addressed range [SCO_EXP, SCO_EXP+NW)
            if (cpu_addr >= SCO_EXP && cpu_addr < SCO_EXP + NW)
                exp[(cpu_addr - SCO_EXP) * 32 +: 32] <= cpu_din;
        end
    end

    // ----- cpu-slave read decode ---------------------------------------------
    always @(*) begin
        cpu_dout = 32'h0000_0000;
        if (cpu_cs && cpu_oe) begin
            if (cpu_addr == REG_ENA)    cpu_dout = {31'd0, ena};
            else if (cpu_addr == REG_MODE)   cpu_dout = mode;
            else if (cpu_addr == REG_ERRCNT) cpu_dout = errcnt;
            else if (cpu_addr == REG_CHKCNT) cpu_dout = chkcnt;
            else if (cpu_addr >= SCO_EXP && cpu_addr < SCO_EXP + NW)
                cpu_dout = exp[(cpu_addr - SCO_EXP) * 32 +: 32];
            else if (cpu_addr >= SCO_FM && cpu_addr < SCO_FM + NW)
                cpu_dout = fm_data[(cpu_addr - SCO_FM) * 32 +: 32];
        end
    end

    // ----- counter clear (separate so it does not race the compare path) -----
    wire clr = cpu_cs && cpu_we && (cpu_addr == REG_CLR) && cpu_din[0];

    // ===== COMPARE BODY (project-specific) ===================================
    // Default (OPTION 2): on every accepted beat, compare in_data against the
    // CPU-supplied expected payload. Adapt the handshake (valid/ready, sof/eof)
    // and the expected-value derivation to this interface.
    always @(posedge clk) begin
        if (!rst_n || clr) begin
            errcnt <= 32'd0; chkcnt <= 32'd0; fm_data <= '0;
        end else if (ena && in_valid && in_ready) begin
            chkcnt <= chkcnt + 32'd1;
            if (in_data !== exp) begin
                if (errcnt == 32'd0) fm_data <= in_data;   // capture first mismatch
                errcnt <= errcnt + 32'd1;
                $display("[ERROR] time= %0t, sco_{{IFACE}} beat %0d MISMATCH: expected 0x%0h got 0x%0h",
                         $time, chkcnt, exp, in_data);
                $display("[FINISH] FAIL");
                $finish;
            end
        end
    end
    // ========================================================================

endmodule
