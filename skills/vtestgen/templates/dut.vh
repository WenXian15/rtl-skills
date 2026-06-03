//==============================================================================
// dut.vh : the reusable bench core for {{MODULE}}
//   - register-map localparams (CPU address constants)
//   - declarations for every DUT port
//   - the DUT instantiation
//   - instantiation of every sti_*.sv stimulus driver, wired to the SAME cpu bus
//   - a cpu-bus read mux across DUT + stimulus slaves
//   - the cpu_write / cpu_read / cpu_read_check bus-functional tasks
//
// A testcase declares the DUT parameters (ID_BIT, DATA_W, RS_LV, ...) and the
// cpu access latencies (CPU_WR_LAT, CPU_RD_LAT) before `include "dut.vh", then
// drives EVERYTHING through cpu_write/cpu_read_check.
//==============================================================================

    //=========================================================================
    // register map  (CPU address constants)
    //   low space  : DUT registers  (MUST be < STI_BASE -- the read mux below
    //                routes everything >= STI_BASE to the sti/sco slaves)
    //   mid space  : stimulus (sti_*) control registers, base STI_BASE
    //   high space : scoreboard (sco_*) status registers, base SCO_BASE
    //   each sti_*/sco_* slave owns a 0x100-word window (base + i*0x100), big
    //   enough for any width-dependent payload (NW = DATA_W/32) up to 256 words.
    //=========================================================================
    localparam STI_BASE         = 20'h8000;   // stimulus base (slave i at +i*'h100)
    localparam SCO_BASE         = 20'hC000;   // scoreboard base (slave i at +i*'h100)
{{REGISTER_MAP}}
    localparam ADDR_NULL        = 20'hFFFFF;

    //=========================================================================
    // cpu bus  (single control plane for the whole bench)
    //=========================================================================
    reg                         cpu_cs;
    reg                         cpu_we;
    reg                         cpu_oe;
    reg  [19:0]                 cpu_addr;
    reg  [31:0]                 cpu_din;
    wire [31:0]                 cpu_dout;       // muxed read data (DUT | sti | sco)

    //=========================================================================
    // DUT port signals
    //   inputs driven by the bench are reg, outputs from the DUT are wire.
    //   data-plane inputs are wires driven by the sti_*.sv modules.
    //=========================================================================
{{DUT_SIGNALS}}

    //=========================================================================
    // DUT instantiation
    //=========================================================================
    {{MODULE}} #(
{{DUT_PARAM_MAP}}
    ) u_dut (
{{DUT_PORT_MAP}}
    );

    //=========================================================================
    // stimulus drivers (sti_*.sv) - each is a CPU-bus slave in STI space.
    //   The test script configures/starts them with cpu_write only.
    //   Each exposes <name>_dout; OR/mux them into cpu_dout below.
    //=========================================================================
{{STI_INSTANCES}}

    //=========================================================================
    // scoreboards (sco_*.sv) - each is a CPU-bus slave in SCO space.
    //   Each taps a DUT data-plane output, checks it continuously, and exposes
    //   a mismatch counter + first-mismatch info as CPU-readable status regs.
    //   Each exposes <name>_dout; OR/mux them into cpu_dout below.
    //   Omit this section (and SCO_BASE) for IPs with no checkable stream output.
    //=========================================================================
{{SCO_INSTANCES}}

    // read-data mux: DUT below STI_BASE; sti + sco slaves above (each drives 0
    // unless addressed, so OR-combining their douts is safe). When a group is
    // empty, the generator substitutes 32'h0 for its OR term.
    assign cpu_dout = (cpu_addr >= STI_BASE) ? ({{STI_DOUT_OR}} | {{SCO_DOUT_OR}})
                                             : dut_cpu_dout;

    //=========================================================================
    // bus-functional tasks  (timed against the cpu clock domain)
    //   Access length is parameterized: CPU_WR_LAT / CPU_RD_LAT cpu clocks
    //   (declared by the parent testcase, default 1). Set them higher for a
    //   slave whose read/write takes more than one cycle. For a slave with a
    //   variable-latency ready/ack handshake, poll that signal instead of using
    //   a fixed latency.
    //=========================================================================
    task cpu_write;
        input   [19:0]  addr;
        input   [31:0]  data;
    begin
        @(posedge {{CPU_CLK}});
        #(0.1);
        cpu_addr = addr;
        cpu_din  = data;
        cpu_cs   = 1'b1;
        cpu_we   = 1'b1;
        cpu_oe   = 1'b0;
        #(CPU_WR_LAT * T_{{CPU_CLK_UPPER}});   // hold the access CPU_WR_LAT cycles
        cpu_we   = 1'b0;
        cpu_cs   = 1'b0;
        #(T_{{CPU_CLK_UPPER}});
        `ifdef LOG_CPU_ACCESS
        $display("[INFO] time= %0t, CPU Write 0x%5x = 0x%8x", $time, addr, data);
        `endif
    end
    endtask

    task cpu_read;
        input   [19:0]  addr;
        output  [31:0]  data;
    begin
        @(posedge {{CPU_CLK}});
        #(0.1);
        cpu_addr = addr;
        cpu_cs   = 1'b1;
        cpu_we   = 1'b0;
        cpu_oe   = 1'b1;
        #(CPU_RD_LAT * T_{{CPU_CLK_UPPER}});   // wait CPU_RD_LAT cycles for read data
        data     = cpu_dout;
        cpu_oe   = 1'b0;
        cpu_cs   = 1'b0;
        #(T_{{CPU_CLK_UPPER}});
        `ifdef LOG_CPU_ACCESS
        $display("[INFO] time= %0t, CPU Read 0x%5x = 0x%8x", $time, addr, data);
        `endif
    end
    endtask

    // read-and-compare: prints [FINISH] FAIL and $finish on mismatch
    task cpu_read_check;
        input   [19:0]  addr;
        input   [31:0]  data;
    begin
        @(posedge {{CPU_CLK}});
        #(0.1);
        cpu_addr = addr;
        cpu_cs   = 1'b1;
        cpu_we   = 1'b0;
        cpu_oe   = 1'b1;
        #(CPU_RD_LAT * T_{{CPU_CLK_UPPER}});   // wait CPU_RD_LAT cycles for read data
        if (cpu_dout !== data) begin           // sample while oe still asserted
            $display("[ERROR] time= %0t, CPU Read 0x%5x = 0x%8x, MISMATCH, expected 0x%8x",
                     $time, addr, cpu_dout, data);
            $display("[FINISH] FAIL");
            $finish;
        end
        `ifdef LOG_CPU_ACCESS
        else
            $display("[INFO] time= %0t, CPU ReadChk 0x%5x = 0x%8x OK", $time, addr, cpu_dout);
        `endif
        cpu_oe   = 1'b0;
        cpu_cs   = 1'b0;
        #(T_{{CPU_CLK_UPPER}});
    end
    endtask

    //=========================================================================
    // reusable sequences  (built on the BFM tasks; shared by every testcase)
    //   Put any multi-step CPU sequence more than one testcase repeats here, so
    //   tb_*.sv stays pure intent (load_key, cfg_run, sti_load, ...).
    //
    //   Below is the stream arm-and-sync handshake that aligns an sti_* driver
    //   with its mirroring sco_* at run time. UNCOMMENT and keep it if this bench
    //   has a driver+scoreboard pair; drop the sco half (and check_stream) if the
    //   IP has no scoreboard. The offsets match sti_template.sv / sco_template.sv.
    //=========================================================================
    // sti_* register offsets             // sco_* register offsets
    // localparam STI_OFF_ENA  = 0;       localparam SCO_OFF_ENA  = 0;
    // localparam STI_OFF_RATE = 1;       localparam SCO_OFF_MODE = 1;
    // localparam STI_OFF_MODE = 2;       localparam SCO_OFF_CLR  = 2;
    // localparam STI_OFF_SEED = 3;       localparam SCO_OFF_SEED = 3;
    // localparam STI_OFF_CNT  = 4;       localparam SCO_OFF_ERR  = 4;
    // localparam STI_OFF_CLR  = 5;       localparam SCO_OFF_CHK  = 5;
    //
    // arm_stream: put a driver+scoreboard pair on the same MODE/SEED and start
    // them from the head of the sequence. The sco is enabled BEFORE the driver so
    // it never misses the first output beat; alignment then survives DUT latency
    // and back-pressure as long as the DUT carries the stream 1:1 in order (see
    // the sti_/sco_template headers for the mirror-validity rule).
    // task arm_stream;
    //     input [19:0] sti_base;
    //     input [19:0] sco_base;
    //     input [31:0] mode;
    //     input [31:0] seed;
    //     input [31:0] rate;     // sti throttle: idle cycles between beats (0 = every cycle)
    // begin
    //     cpu_write(sti_base + STI_OFF_ENA,  32'd0);   // stop driver
    //     cpu_write(sco_base + SCO_OFF_ENA,  32'd0);   // stop scoreboard
    //     cpu_write(sti_base + STI_OFF_SEED, seed);    // same seed ...
    //     cpu_write(sco_base + SCO_OFF_SEED, seed);
    //     cpu_write(sti_base + STI_OFF_MODE, mode);    // ... and same mode
    //     cpu_write(sco_base + SCO_OFF_MODE, mode);
    //     cpu_write(sti_base + STI_OFF_CLR,  32'd1);   // arm both from start
    //     cpu_write(sco_base + SCO_OFF_CLR,  32'd1);
    //     cpu_write(sco_base + SCO_OFF_ENA,  32'd1);   // enable sco FIRST
    //     cpu_write(sti_base + STI_OFF_RATE, rate);
    //     cpu_write(sti_base + STI_OFF_ENA,  32'd1);   // then start the driver
    // end
    // endtask
    //
    // check_stream: end-of-run verdict for a deferred (non-self-failing) check.
    // task check_stream;
    //     input [19:0] sco_base;
    // begin
    //     cpu_read_check(sco_base + SCO_OFF_ERR, 32'd0);   // expect 0 mismatches
    // end
    // endtask
