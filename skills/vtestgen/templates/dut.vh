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
    //   low space  : DUT registers
    //   mid space  : stimulus (sti_*) control registers, base STI_BASE
    //   high space : scoreboard (sco_*) status registers, base SCO_BASE
    //=========================================================================
    localparam STI_BASE         = 20'h8000;   // stimulus config base address
    localparam SCO_BASE         = 20'hC000;   // scoreboard config/status base
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
