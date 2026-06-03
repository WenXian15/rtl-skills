//==============================================================================
// tb_{{MODULE}}_basic.sv : starter self-checking testcase for {{MODULE}}
//   The bench is driven ENTIRELY through the cpu bus (cpu_write/cpu_read_check).
//   Pass/fail contract: print "[FINISH] PASS" (or FAIL) then $finish.
//==============================================================================
`timescale 1ns/1ps

module tb_{{MODULE}}_basic;

    //----- clock periods + reset level (consumed by clock.vh) ----------------
{{CLK_PARAMS}}
    // RS_LV = reset active level (1-bit). vtestgen sets this to the DUT's own
    // RS_LV default (parsed from <ip>_top) so the bench drives reset at the
    // polarity the DUT expects; the project default is 1'b0 (active-low). Keep
    // it 1-bit so the `=== ~RS_LV` reset-release compare below stays bit-accurate.
    parameter RS_LV = 1'b0;

    //----- cpu access latency (cpu clocks the bus is held per access) --------
    // default 1 = single-cycle access; raise for a slave that needs more cycles
    parameter CPU_WR_LAT = 1;
    parameter CPU_RD_LAT = 1;

    //----- clock/reset regs ---------------------------------------------------
{{CLK_REGS}}

    `include "clock.vh"

    //----- DUT parameters -----------------------------------------------------
{{DUT_PARAMS}}

    `include "dut.vh"

    //----- watchdog -----------------------------------------------------------
    parameter T_TIMEOUT = 200000 * T_{{SYS_CLK_UPPER}};
    initial begin
        #(T_TIMEOUT);
        $display("[ERROR] time= %0t, WATCHDOG TIMEOUT", $time);
        $display("[FINISH] FAIL");
        $finish;
    end

    //=========================================================================
    // test script  (CPU read/write ONLY)
    //=========================================================================
    initial begin
        cpu_cs = 0; cpu_we = 0; cpu_oe = 0; cpu_addr = 0; cpu_din = 0;

        // wait reset release (polarity-agnostic: the deasserted level is ~RS_LV)
        wait (rst_n_{{SYS_CLK}} === ~RS_LV);
        #(100*T_{{CPU_CLK_UPPER}});

        // --- example: configure the DUT via its register map ----------------
        // cpu_write(REG_MODE, 32'h0000_0001);
        // cpu_read_check(REG_MODE, 32'h0000_0001);

        // --- example: configure + start stimulus through the cpu bus --------
        // cpu_write(STI_BASE + 1, 32'd2);     // rate
        // cpu_write(STI_BASE + 0, 32'd1);     // enable

        // --- let traffic run, then check DUT status -------------------------
        #(10000*T_{{SYS_CLK_UPPER}});
        // cpu_read_check(REG_STATUS, 32'h0000_0000);

        $display("[INFO] time= %0t, TEST PASS!!!", $time);
        $display("[FINISH] PASS");
        $finish;
    end

endmodule
