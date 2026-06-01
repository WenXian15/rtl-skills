//==============================================================================
// sti_{{IFACE}}.sv : CPU-controllable stimulus driver for the {{IFACE}} interface
//
// Architecture contract (every sti_*.sv must follow this):
//   * It is a CPU-bus SLAVE. It self-decodes its own address slice in STI space
//     (base passed via parameter STI_ADDR). The test script controls it with
//     cpu_write only -- no direct poking from the testcase.
//   * Config registers (write):  ENA (start/stop), RATE, MODE, SEED, ...
//   * Status  registers (read) :  via <name>_dout when addressed.
//   * It produces the data-plane signals consumed by the DUT.
//
// Replace the GENERATOR BODY with whatever traffic this project needs
// (calendar/stream, packet bursts, prbs, AXI, raw vectors, ...). Only the body
// changes between projects; the CPU-slave wrapper stays identical.
//==============================================================================
`timescale 1ns/1ps

module sti_{{IFACE}} #(
    parameter STI_ADDR = 20'h8000,   // this driver's config base in STI space
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

    // data-plane outputs to the DUT
    output reg                  out_valid,
    output reg  [DATA_W-1:0]    out_data
);

    // ----- local config register addresses (offsets from STI_ADDR) -----------
    localparam REG_ENA  = STI_ADDR + 0;   // [0] enable generation
    localparam REG_RATE = STI_ADDR + 1;   // cycles-per-beat (throttle)
    localparam REG_MODE = STI_ADDR + 2;   // pattern/mode select
    localparam REG_SEED = STI_ADDR + 3;   // prng seed

    reg        ena;
    reg [31:0] rate;
    reg [31:0] mode;
    reg [31:0] seed;

    // ----- cpu-slave write decode --------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
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
                default : cpu_dout = 32'h0000_0000;
            endcase
        end
    end

    // ===== GENERATOR BODY (project-specific) =================================
    // Example: throttled pseudo-random beat generator. Replace as needed.
    reg [31:0] thr;
    reg [31:0] lfsr;
    always @(posedge clk) begin
        if (!rst_n) begin
            thr <= 32'd0; lfsr <= seed; out_valid <= 1'b0; out_data <= '0;
        end else if (ena) begin
            if (thr >= rate) begin
                thr       <= 32'd0;
                lfsr      <= {lfsr[30:0], lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};
                out_valid <= 1'b1;
                out_data  <= lfsr[DATA_W-1:0];
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
