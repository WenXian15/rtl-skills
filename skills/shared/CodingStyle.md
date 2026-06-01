# Verilog Coding Style

The following rules must be followed.

## General File Appearance

- Wrap the code at 100 characters per line. Exceptions: Any place where line wraps are impossible (for example, an include path might extend past 100 characters).

- Do not use tabs anywhere. Use four spaces for indentation.

- Remove trailing whitespace at the end of each line.

- Use begin and end unless the whole statement fits on a single line.

- Always use synchronous reset. If the module has no parameter `RS_LV`, set reset active-low. If it has parameter `RS_LV`, set reset active level as `RS_LV`.

- Blocking/non-blocking assignment rule: always use `<=` in `always @(posedge clk)`, and use `=` in `always @(*)`.

## Signal Naming

Signal names must follow the format: `[<pipeline_name>_][<pipeline stage>_]<signal_name>[_ff]`

where
- `<pipeline_name>` is the name of pipeline process. Use this field only if the design contains more than one pipeline process. It helps distinguish between different pipeline paths. This field must be concise, no more than 3 characters. 
- `<pipeline_stage>` can be `s0`, `s1`, `s2`... corresponding to stages 0, 1, 2... Stage `s0` represents the cycle in which the pipeline input becomes valid.
- `[_ff]` is only used when the signal is expected to synthesize into a flip-flop or register.

Example:
- `s0_cnt` : the `cnt` signal at stage 0 (corresponding to the valid input)
- `req_ff` : the `req` signal not according to the pipeline design, which will be synthesized into a flip-flop

If the design has pipeline process, you must add `[<pipeline stage>_]` to all names, except for memory signals and in/out ports.

## Bus Naming

- Bus names should be kept as short as possible. Examples: `axi`, `upi`, `ob00`.
- For input/output ports, use the following prefixes:
  - `s_` for slave interfaces
  - `m_` for master interfaces
  - `b_` for monitor interfaces
- If a bus is used as an internal connection between submodules, its name must follow this format `<master>2<slave>_<bus_name>[_<bus_inst>]`. Where:
  - `<master>` is the abbreviated instance name of the master module and must not exceed 3 characters
  - `<slave>` is the abbreviated instance name of the slave module and must not exceed 3 characters
  - `<bus_name>` is the short name of the bus type
  - `[_<bus_inst>]` is optional. This field should be used only when more than one bus of the same type connects the same pair of modules, in order to distinguish between them.

## Others

- Moore FSM: single `always` block for both state and output
- Mealy FSM: one `always` block for state, separate `always @(*)` block for output logic.
- Constant/FSM states must use localparam with explicit values:
```
localparam FSM_IDLE   = 'd0,
           FSM_ENCODE = 'd1,
           FSM_DONE   = 'd2;
```

## Language Standard

These rules apply to **synthesizable code in `rtl/` and `lib/`**:

- Write in Verilog-2001. Do not use SystemVerilog constructs.
- Use `reg` and `wire` declarations, not `logic`.
- Use `always @(posedge clk)` and `always @(*)`, not `always_ff` or `always_comb`.

**Testbench code under `tb/` is exempt.** Benches are not synthesized, so
SystemVerilog (`.sv`) is permitted there — this is the language of the
`vtestgen` bench (`dut.vh`, `clock.vh`, `sti_*.sv`, `tb_*.sv`). Synchronous-reset
and blocking/non-blocking rules above still apply for readability.

## Comment

- C++ style comments (`// foo`) are preferred. C style comments (`/* bar */`) can also be used.

- split code section by comment like below
```
//==============================================================================
// <code section>
//==============================================================================
```

## Design Direction Markers (`//!`)

`//!` comments are design-direction markers: instructions that tell `vfill` what
logic to implement. They are temporary scaffolding, not permanent documentation.

### Syntax

- A single-line comment whose leading token is `//!`. Write it as `//! <direction>`.
- One direction per line, placed on its own line in the code section where the
  described logic belongs.

### Content

- Plain-English design intent only — describe *what* to implement, never *how*.
- A marker must never contain Verilog code: no assignments, expressions, or
  operators that form valid RTL. Refer to signals by name in prose instead.

### Lifecycle

- **Created by** `vdesign` in `rtl/<module>.v` backbones, and by `varch` as
  integration notes in `rtl/<ip>_top.v`.
- **Consumed by** `vfill`: once the described logic is implemented, `vfill` must
  convert every `//!` to a normal `//` comment (or remove it). No `//!` may
  remain in a completed module.
- `vflow` detects implementation completion (Phase 3) by the **absence** of
  `//!` in `rtl/` excluding `_top.v`. A single stray `//!` keeps the module
  marked IN PROGRESS, so an unconverted marker silently blocks the flow.
- Integration markers in `rtl/<ip>_top.v` are excluded from Phase 3 detection;
  they are resolved during IP integration, not during submodule fill.

## Testbench Verdict Token

Every `vtestgen` testcase ends by printing exactly one verdict token, then
`$finish`:

- `[FINISH] PASS` when the testcase passed.
- `[FINISH] FAIL` on any mismatch or timeout. The shared `cpu_read_check` task
  emits `[FINISH] FAIL` automatically on a read mismatch.

This token — not the presence of any `[ERROR]` text — is the single
machine-readable result. The bench Makefiles and `vtestrun` decide pass/fail by
grepping for `FINISH` and reading the following word; absence of the token is
treated as FAIL (crash, or never reached the result line). Diagnostic context is
printed on `[ERROR] time= ... ` lines, which `vtestrun` harvests into issue
reports but does not use for the pass/fail decision.
