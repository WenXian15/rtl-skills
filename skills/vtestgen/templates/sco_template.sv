//==============================================================================
// sco_{{IFACE}}.sv : CPU-controllable scoreboard for the {{IFACE}} data-plane output
//
// Architecture contract (every sco_*.sv must follow this):
//   * It is a CPU-bus SLAVE. It self-decodes its own address slice in SCO space
//     (base passed via parameter SCO_ADDR; each slave owns a 0x100-word window,
//     so keep all register offsets below 'h100 -- the FM capture at +8 spans NW
//     words). The test script controls it with cpu_write only and reads results
//     with cpu_read/cpu_read_check.
//   * It TAPS a DUT data-plane output (it never drives the DUT) and checks each
//     accepted beat continuously against an expected value.
//   * Config registers (write):  ENA (start/stop checking), MODE (expected-source
//     select), SEED (LFSR seed), CLR (clear counters + reseed the generator).
//   * Status registers (read) :  ERRCNT (mismatches), CHKCNT (beats checked),
//     and the word-addressed first-mismatch capture FM, via <name>_dout.
//   * On a mismatch it prints "[ERROR] ..." then "[FINISH] FAIL" and $finish
//     (self-fail, like cpu_read_check). ERRCNT is still exposed so a testcase
//     can instead defer the verdict with cpu_read_check(SCO_ERRCNT, 0).
//
// Expected-value source (default): the scoreboard REGENERATES the expected stream
// itself, mirroring the matching sti_* driver -- no per-word expected payload is
// pushed over the CPU bus. Select the source with REG_MODE (and REG_SEED for
// LFSR) so they match the driver:
//   MODE_LFSR  (0) : pseudo-random LFSR, replicated to DATA_W
//   MODE_COUNT (1) : byte-stream counter-up
//   MODE_FILE  (2) : replay DATA_W-wide words from PATTERN_FILE ($readmemh)
//
// MIRROR VALIDITY: this works only when the DUT carries the stream 1:1 and in
// order (FIFO/CDC/width-matched passthrough). Runtime sync: set the SAME
// MODE/SEED on this sco and the driver, pulse CLR on BOTH to arm from the start
// of the sequence, then enable this sco before the driver. The expected counter
// advances per accepted beat, so DUT latency/back-pressure do not desync it. If
// the DUT drops/reorders/transforms beats, use the reference-model alternative.
// Alternatives for the COMPARE BODY:
//   - reference model: recompute expected from observed DUT inputs (use only when
//     the transform is non-trivial);
//   - CPU-supplied payload: add a word-addressed EXP register written by the
//     testcase (the old default) when the expected data is not a regular sequence.
// Only the COMPARE BODY changes between projects; the CPU-slave wrapper stays.
//==============================================================================
`timescale 1ns/1ps

module sco_{{IFACE}} #(
    parameter SCO_ADDR      = 20'hC000,   // this scoreboard's config/status base
    parameter DATA_W        = {{DATA_W}},
    parameter PATTERN_FILE  = "",         // hex file for MODE_FILE replay ($readmemh)
    parameter PATTERN_DEPTH = 256         // entries in the replay memory
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
    localparam NW = (DATA_W + 31) / 32;          // 32-bit words per beat
    localparam NB = (DATA_W + 7)  / 8;           // bytes per beat

    // ----- config / status register addresses (offsets from SCO_ADDR) --------
    localparam REG_ENA    = SCO_ADDR + 0;        // [0] enable checking
    localparam REG_MODE   = SCO_ADDR + 1;        // expected-source select (MODE_*)
    localparam REG_CLR    = SCO_ADDR + 2;        // write 1 -> clear counters + reseed
    localparam REG_SEED   = SCO_ADDR + 3;        // LFSR seed (match the sti_* driver)
    localparam REG_ERRCNT = SCO_ADDR + 4;        // (ro) mismatch count
    localparam REG_CHKCNT = SCO_ADDR + 5;        // (ro) beats checked
    localparam SCO_FM     = SCO_ADDR + 8;        // (ro) first-mismatch capture, word i at +8+i

    reg                  ena;
    reg [31:0]           mode;
    reg [31:0]           seed;
    reg [31:0]           errcnt;
    reg [31:0]           chkcnt;
    reg [DATA_W-1:0]     fm_data;                // first mismatched beat captured

    // ----- cpu-slave write decode --------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            ena <= 1'b0; mode <= 32'd0; seed <= 32'd1;
        end else if (cpu_cs && cpu_we) begin
            if (cpu_addr == REG_ENA)  ena  <= cpu_din[0];
            if (cpu_addr == REG_MODE) mode <= cpu_din;
            if (cpu_addr == REG_SEED) seed <= cpu_din;
        end
    end

    // ----- cpu-slave read decode ---------------------------------------------
    always @(*) begin
        cpu_dout = 32'h0000_0000;
        if (cpu_cs && cpu_oe) begin
            if (cpu_addr == REG_ENA)         cpu_dout = {31'd0, ena};
            else if (cpu_addr == REG_MODE)   cpu_dout = mode;
            else if (cpu_addr == REG_SEED)   cpu_dout = seed;
            else if (cpu_addr == REG_ERRCNT) cpu_dout = errcnt;
            else if (cpu_addr == REG_CHKCNT) cpu_dout = chkcnt;
            else if (cpu_addr >= SCO_FM && cpu_addr < SCO_FM + NW)
                cpu_dout = fm_data[(cpu_addr - SCO_FM) * 32 +: 32];
        end
    end

    // ----- counter clear (separate so it does not race the compare path) -----
    wire clr = cpu_cs && cpu_we && (cpu_addr == REG_CLR) && cpu_din[0];

    // ===== EXPECTED-SEQUENCE GENERATOR + COMPARE BODY ========================
    // The scoreboard regenerates the expected stream itself (no expected payload
    // over the bus), mirroring the matching sti_* driver. One expected value is
    // consumed per accepted beat (in_valid && in_ready). Set REG_MODE/REG_SEED to
    // match the driver; SEED takes effect at reset and on CLR (like the driver's
    // reset-seeding). Everything is sized off DATA_W -- no hardcoded width.
    localparam MODE_COUNT = 32'd1;        // mode 0 (default) = LFSR
    localparam MODE_FILE  = 32'd2;

    // file-replay memory: one DATA_W-wide hex entry per line of PATTERN_FILE
    reg [DATA_W-1:0] pat_mem [0:PATTERN_DEPTH-1];
    integer          pat_init;
    initial begin
        for (pat_init = 0; pat_init < PATTERN_DEPTH; pat_init = pat_init + 1)
            pat_mem[pat_init] = {DATA_W{1'b0}};
        if (PATTERN_FILE != "") $readmemh(PATTERN_FILE, pat_mem);
    end

    reg [31:0]       elfsr;    // expected LFSR state
    reg [31:0]       ecnt;     // expected byte counter-up base
    reg [31:0]       pidx;     // expected file-replay index
    integer          b;

    // combinational expected value for the current beat (mirrors sti_* exactly)
    reg [DATA_W-1:0] exp;
    always @(*) begin
        case (mode)
            MODE_COUNT: begin
                exp = {DATA_W{1'b0}};
                for (b = 0; b < NB; b = b + 1) exp[b*8 +: 8] = 8'(ecnt + b);
            end
            MODE_FILE: exp = pat_mem[pidx];
            default:   exp = {NW{elfsr}};   // LFSR replicated, truncated to DATA_W
        endcase
    end

    always @(posedge clk) begin
        if (!rst_n || clr) begin
            errcnt <= 32'd0; chkcnt <= 32'd0; fm_data <= {DATA_W{1'b0}};
            elfsr  <= seed;  ecnt <= 32'd0;  pidx <= 32'd0;
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
            // advance the expected generator for the next accepted beat
            elfsr <= {elfsr[30:0], elfsr[31]^elfsr[21]^elfsr[1]^elfsr[0]};
            ecnt  <= ecnt + NB;
            pidx  <= (pidx == PATTERN_DEPTH-1) ? 32'd0 : pidx + 32'd1;
        end
    end
    // ========================================================================

endmodule
