//==============================================================================
// clock.vh : parameterized clock + synchronous reset generators
// Included by every tb_*.sv. The parent testcase declares the clk/rst regs and
// the period parameters (T_<NAME>) and reset level (RS_LV) before `include.
//==============================================================================

    // ----- clocks ------------------------------------------------------------
    // For each clock {{CLK}} with period parameter T_{{CLK_UPPER}}:
    initial {{CLK}} = 0;
    always
        #(T_{{CLK_UPPER}}/2) {{CLK}} = ~{{CLK}};

    // ----- synchronous resets ------------------------------------------------
    // One reset per clock domain, named rst_n_<clk>. Active level is RS_LV
    // (default 0 = active-low: assert to RS_LV, deassert to ~RS_LV).
    // De-assert after 10 clock periods.
    initial begin
        {{RST}} = RS_LV;
        #(10*T_{{CLK_UPPER}});
        {{RST}} = ~RS_LV;
    end
