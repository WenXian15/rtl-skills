//==============================================================================
// sti_{{IFACE}}.sv : CPU-controllable stimulus driver for the {{IFACE}} interface
//
// Architecture contract (every sti_*.sv must follow this):
//   * It is a CPU-bus SLAVE. It self-decodes its own address slice in STI space
//     (base passed via parameter STI_ADDR; each slave owns a 0x100-word window,
//     so keep all register offsets below 'h100). The test script controls it with
//     cpu_write only -- no direct poking from the testcase.
//   * Config registers (write):  ENA (start/stop), RATE, MODE, SEED, CLR (arm).
//   * Status  registers (read) :  CNT (beats emitted) via <name>_dout.
//   * It produces the data-plane signals consumed by the DUT.
//
// Runtime sync with a mirroring sco_*: set the SAME MODE/SEED on both, pulse CLR
// on both to arm them from the start of the sequence, then enable the sco before
// this driver. The sco advances per accepted DUT-output beat, so alignment then
// holds across DUT latency and back-pressure -- PROVIDED the DUT carries the
// stream 1:1 in order (FIFO/CDC/passthrough). If the DUT drops, reorders, or
// transforms beats, the mirror is invalid; use a reference-model sco instead.
//
// The GENERATOR BODY is MODE-selectable (chosen at run time via the MODE
// register): pseudo-random LFSR, byte-stream counter-up, or replay of a pattern
// held in an external hex file. Add/replace modes for whatever traffic this
// project needs (calendar/stream, packet bursts, AXI, ...). Only the body
// changes between projects; the CPU-slave wrapper stays identical.
//==============================================================================
`timescale 1ns/1ps

module sti_{{IFACE}} #(
    parameter STI_ADDR      = 20'h8000,   // this driver's config base in STI space
    parameter DATA_W        = {{DATA_W}},
    parameter PATTERN_FILE  = "",         // hex file for MODE_FILE replay ($readmemh)
    parameter PATTERN_DEPTH = 256,        // entries in the replay memory
    parameter RS_LV         = 1'b0        // reset active level; MUST match the DUT
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

    // data-plane source handshake to the DUT
    input  wire                 out_ready,    // tie to 1'b1 if the iface has no ready
    output reg                  out_valid,
    output reg  [DATA_W-1:0]    out_data
);

    // ----- local config register addresses (offsets from STI_ADDR) -----------
    localparam REG_ENA  = STI_ADDR + 0;   // [0] enable generation
    localparam REG_RATE = STI_ADDR + 1;   // idle cycles between beats (0 = every cycle)
    localparam REG_MODE = STI_ADDR + 2;   // pattern/mode select (MODE_*)
    localparam REG_SEED = STI_ADDR + 3;   // prng seed
    localparam REG_CNT  = STI_ADDR + 4;   // (ro) beats emitted so far
    localparam REG_CLR  = STI_ADDR + 5;   // write 1 -> arm/reseed generator to start

    reg        ena;
    reg [31:0] rate;
    reg [31:0] mode;
    reg [31:0] seed;
    reg [31:0] sent;                      // beats emitted (read-only status)

    // ----- cpu-slave write decode --------------------------------------------
    always @(posedge clk) begin
        if (rst_n == RS_LV) begin
            ena <= 1'b0; rate <= 32'd1; mode <= 32'd0; seed <= 32'd1;
        end else if (cpu_cs && cpu_we) begin
            case (cpu_addr)
                REG_ENA : ena  <= cpu_din[0];
                REG_RATE: rate <= cpu_din;
                REG_MODE: mode <= cpu_din;
                REG_SEED: seed <= cpu_din;
                default : ;
            endcase
        end
    end

    // ----- cpu-slave read decode ---------------------------------------------
    always @(*) begin
        cpu_dout = 32'h0000_0000;
        if (cpu_cs && cpu_oe) begin
            case (cpu_addr)
                REG_ENA : cpu_dout = {31'd0, ena};
                REG_RATE: cpu_dout = rate;
                REG_MODE: cpu_dout = mode;
                REG_SEED: cpu_dout = seed;
                REG_CNT : cpu_dout = sent;
                default : cpu_dout = 32'h0000_0000;
            endcase
        end
    end

    // ===== GENERATOR BODY (project-specific) =================================
    // Throttled beat generator with a run-time-selectable source (REG_MODE):
    //   MODE_LFSR  (0) : pseudo-random LFSR, replicated to fill DATA_W
    //   MODE_COUNT (1) : byte-stream counter-up (bytes increment across beats)
    //   MODE_FILE  (2) : replay DATA_W-wide words from PATTERN_FILE, looping
    // RATE throttles every mode (idle cycles between beats; 0 = every cycle);
    // SEED seeds the LFSR. The source honors out_ready: a beat is held until
    // accepted (out_valid && out_ready) and the generator advances only then, so
    // it stays in lock-step with a mirroring sco_* under back-pressure. All sizing
    // is derived from DATA_W -- nothing here hardcodes the data width.
    localparam MODE_COUNT = 32'd1;        // mode 0 (default) = LFSR
    localparam MODE_FILE  = 32'd2;

    localparam NB = (DATA_W + 7)  / 8;     // bytes per beat
    localparam NW = (DATA_W + 31) / 32;    // 32-bit words per beat

    // arm/reseed: a single-cycle pulse that restarts the generator from SEED
    // (offset 0). Pulse it on BOTH this driver and the mirroring sco_* (write 1
    // to each CLR) to re-align them at run time without a full DUT reset.
    wire clr = cpu_cs && cpu_we && (cpu_addr == REG_CLR) && cpu_din[0];

    // file-replay memory: one DATA_W-wide hex entry per line of PATTERN_FILE
    reg [DATA_W-1:0] pat_mem [0:PATTERN_DEPTH-1];
    integer          pat_init;
    initial begin
        for (pat_init = 0; pat_init < PATTERN_DEPTH; pat_init = pat_init + 1)
            pat_mem[pat_init] = {DATA_W{1'b0}};
        if (PATTERN_FILE != "") $readmemh(PATTERN_FILE, pat_mem);
    end

    reg [31:0] thr;        // throttle counter
    reg [31:0] lfsr;       // prng state
    reg [31:0] bcnt;       // byte counter-up base
    reg [31:0] pat_idx;    // file-replay index
    integer    b;

    always @(posedge clk) begin
        if (rst_n == RS_LV || clr) begin
            // seed 0 would lock the LFSR at all-zeros; coerce to 1. The mirroring
            // sco_* applies the identical coercion, so the two stay aligned.
            thr <= 32'd0; lfsr <= (seed == 32'd0) ? 32'd1 : seed; bcnt <= 32'd0; pat_idx <= 32'd0;
            sent <= 32'd0; out_valid <= 1'b0; out_data <= {DATA_W{1'b0}};
        end else if (out_valid && !out_ready) begin
            // beat pending acceptance: hold data + valid, advance nothing (even
            // if ENA drops here, so the in-flight beat is never lost or skipped)
        end else if (ena) begin
            if (thr >= rate) begin
                thr       <= 32'd0;
                out_valid <= 1'b1;
                sent      <= sent + 32'd1;
                case (mode)
                    MODE_COUNT: begin
                        for (b = 0; b < NB; b = b + 1)
                            out_data[b*8 +: 8] <= 8'(bcnt + b);   // 8-bit byte values
                        bcnt <= bcnt + NB;
                    end
                    MODE_FILE: begin
                        out_data <= pat_mem[pat_idx];
                        pat_idx  <= (pat_idx == PATTERN_DEPTH-1) ? 32'd0 : pat_idx + 32'd1;
                    end
                    default: begin  // MODE_LFSR
                        lfsr     <= {lfsr[30:0], lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};
                        out_data <= {NW{lfsr}};                     // replicate, truncated to DATA_W
                    end
                endcase
            end else begin
                thr       <= thr + 32'd1;
                out_valid <= 1'b0;
            end
        end else begin
            out_valid <= 1'b0;
        end
    end
    // ========================================================================

endmodule
