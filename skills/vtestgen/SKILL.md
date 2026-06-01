---
name: vtestgen
description: Scaffold a Makefile-driven, CPU-bus-controlled testbench project for an IP and generate a comprehensive set of self-checking testcases, validate each with make, and write a testcase list
---

# Verilog Testcase Generator

## Overview

This skill builds the IP-level test environment in two phases:

- **Phase A — Scaffold the bench project.** Parse `<ip>_top`, then generate a
  reusable, Makefile-driven simulation project under `tb/<ip>/`: build system,
  clock/reset generators, a DUT-instance core, CPU-bus BFM tasks, and one
  CPU-controllable stimulus driver per data interface.
- **Phase B — Plan and generate the suite.** Plan testcases across six mandatory
  categories, write each as a thin `tb_*.sv` that drives the bench **only through
  the CPU bus**, validate each with `make`, and write `tc_list.md`.

`vtestrun` later executes the suite through the same Makefile.

The input is an IP name. The outputs are:

```
tb/<ip>/Makefile              top dispatcher (auto-discovers tb_*.sv)
tb/<ip>/script/library.mk     per-testcase xvlog/xelab/xsim recipe
tb/<ip>/script/rtl.f          generated RTL hierarchy filelist
tb/<ip>/clock.vh              parameterized clock + sync-reset generators
tb/<ip>/dut.vh                reg-map, DUT signals/instance, sti instances, CPU BFM tasks + sequences
tb/<ip>/sti_<iface>.sv        one CPU-controllable stimulus driver per data interface
tb/<ip>/sco_<iface>.sv        one CPU-controllable scoreboard per checkable stream output (optional)
tb/<ip>/tb_<name>.sv          self-checking testcases (CPU-bus only)
tb/<ip>/tc_list.md            testcase index with status
tb/<ip>/sim/<tc>/             disposable build dirs
```

Template files for every artifact live in `templates/` next to this SKILL.md.
Treat them as the canonical shape; fill the `{{...}}` placeholders from the
parsed IP. Testbench code is SystemVerilog (`.sv`) — permitted under `tb/` (see
`.claude/skills/shared/CodingStyle.md`).

**Central design rule — the CPU bus is the single control plane.** Every testcase
drives the whole bench using only `cpu_write` / `cpu_read` / `cpu_read_check` (and
the higher-level sequences built on them in `dut.vh`). The DUT is configured over
the CPU bus; traffic generators live in separate `sti_*.sv` modules that are
themselves CPU-bus slaves, so the test script configures and starts stimulus with
`cpu_write` too.

## Prerequisites

| Tool  | Purpose             | Check             |
|-------|---------------------|-------------------|
| xvlog | compile / lint      | `xvlog --version` |
| xelab | elaborate           | `xelab --version` |
| xsim  | simulate            | `xsim --version`  |
| make  | build orchestration | `make --version`  |

If a required tool is missing, report it and stop — do not fake validation.

---

# Phase A — Scaffold the Bench Project

## Step A1 - Understand the IP and parse the top

Read before generating anything:

1. `./doc/<ip>.md` — full IP behavior, architecture, interface protocols, register map.
2. `./rtl/<ip>_top.v` — exact top-level port list, signal names, and widths.

Parse the top module header and **classify** every port:

| Class                    | How to detect | Bench treatment |
|--------------------------|---------------|-----------------|
| clock                    | name matches `clk*` / `*_clk` | generate in `clock.vh`, period param `T_<NAME>` |
| reset                    | name matches `rst*` / `*_rst*` / `*_n` | generate sync reset in `clock.vh` |
| CPU bus                  | `*cpu*`, or `*_we`/`*_oe`/`*_addr`/`*_din`/`*_dout`, or an APB/AXI-lite-ish group | wire to `cpu_*` and the BFM tasks; build the register map |
| data-plane in            | remaining inputs (valid/data/sof/eof/...) grouped by prefix | driven by an `sti_*.sv` module |
| data-plane out / status  | remaining outputs | status outputs: checked via CPU-readable status registers. A **stream** output (continuous `valid`/`data` beats) gets a `sco_*.sv` scoreboard (Step A6) for per-beat checking |

Also extract **parameters** (name + default, e.g. `DATA_W`, `ID_BIT`, `RS_LV`).

If the IP has **no** CPU bus, still generate the CPU bus in the bench as the
control plane for the `sti_*` drivers, and connect the DUT's data ports directly
to the sti outputs / to observation logic. Note this to the user.

Present a short parse summary (params, classified ports, detected clocks, detected
data interfaces → planned `sti_*` drivers, detected stream outputs → planned
`sco_*` scoreboards) **before** generating files. Adjust on feedback.

## Step A2 - Create the skeleton, copy the build system, generate rtl.f

Create folders `tb/<ip>/` and `tb/<ip>/script/` (and `sim/` is created on demand by
the Makefile). Never delete existing files; if `Makefile` / `script/library.mk`
already exist, diff against the template and only offer to update, do not overwrite
silently.

Copy verbatim:
- `templates/Makefile`   → `tb/<ip>/Makefile`
- `templates/library.mk` → `tb/<ip>/script/library.mk`

Generate `tb/<ip>/script/rtl.f` from `templates/rtl.f`: walk the instantiation
hierarchy of `<ip>_top` following `.claude/skills/shared/HierarchyFilelist.md`, and
list every required file as `RTL_FILES += $(RTL_FOLDER)/...` or
`$(LIB_FOLDER)/...`, top module first. Both Makefiles `include` this fragment, so
it is the single source of the compiled filelist (no wildcard globbing).

## Step A3 - Generate `tb/<ip>/clock.vh`

Expand `templates/clock.vh`: one `always` toggle per detected clock (period
`T_<NAME>`), one synchronous reset per clock domain using `RS_LV` (assert =
`RS_LV`, deassert after `10*T_<NAME>`). One clock is the "system" clock
(`{{SYS_CLK}}`, used by watchdog/run-length); the CPU bus uses `{{CPU_CLK}}` (may
be the same clock).

## Step A4 - Generate `tb/<ip>/dut.vh`

Expand `templates/dut.vh`:

- `{{REGISTER_MAP}}` — `localparam REG_<NAME> = 20'h..;` for every CPU register.
  Take real addresses from `doc/<ip>.md` or the RTL decode; if none exists, emit a
  clearly-marked TODO block with example registers.
- `{{DUT_SIGNALS}}` — declare every DUT port with exact widths/names: bench-driven
  inputs and the CPU bus as `reg`/handled by tasks, DUT outputs as `wire`,
  data-plane inputs as `wire` (driven by sti modules).
- `{{DUT_PARAM_MAP}}` / `{{DUT_PORT_MAP}}` — `.NAME(value)` lines; connect the CPU
  port group to `cpu_*`, data-plane ports to the matching `sti_*` outputs, clocks/
  resets to the generated names. The DUT read-data output connects to a
  `dut_cpu_dout` wire so it can be muxed.
- `{{STI_INSTANCES}}` — one instance per `sti_*.sv` (Step A5), each given a unique
  `STI_ADDR` (`STI_BASE`, `STI_BASE+16`, ...), sharing the CPU bus.
- `{{SCO_INSTANCES}}` — one instance per `sco_*.sv` (Step A6), each given a unique
  `SCO_ADDR` (`SCO_BASE`, `SCO_BASE+32`, ...), sharing the CPU bus and tapping a DUT
  output. Leave empty (and drop `SCO_BASE`) if no scoreboard is generated.
- `{{STI_DOUT_OR}}` / `{{SCO_DOUT_OR}}` — OR of each sti / sco instance's `*_dout`
  for the read mux. Substitute `32'h0` for either term when that group is empty.
- `{{CPU_CLK}}` / `{{CPU_CLK_UPPER}}` — the CPU-domain clock name used by the BFM tasks.

The three BFM tasks (`cpu_write`, `cpu_read`, `cpu_read_check`) are already in the
template; keep them, only fix the clock name. `cpu_read_check` prints
`[FINISH] FAIL` + `$finish` on mismatch — this is the failure path of the contract.

Each access is held for a parameterized number of CPU clocks — `CPU_WR_LAT` for
writes, `CPU_RD_LAT` for reads (declared by the testcase, default 1). Set these
higher when the DUT's CPU slave needs more than one cycle per access; read data is
sampled at the end of the `CPU_RD_LAT` window while `cpu_oe` is still asserted. For
a slave with a variable-latency `ready`/`ack` handshake, poll that signal in the
task instead of using a fixed latency.

**Put reusable high-level sequences in `dut.vh`, not in the testcases.** Any
multi-step CPU sequence more than one testcase will repeat — load a key/config
block, trigger+poll a "done" bit, load a payload word-by-word, fire a beat and wait
for capture, read a payload back — belongs here as a task built on the BFM tasks
(e.g. `load_key`, `cfg_run`, `sti_load`, `sti_read`, `sti_beat`). Make them
width-generic by looping `0..NW-1` over the word-addressed `sti_*` registers. This
keeps every `tb_*.sv` to pure intent and lets a testcase at a different `DW` reuse
the exact same sequences.

## Step A5 - Generate `tb/<ip>/sti_<iface>.sv` per data interface

For each data-plane input group from Step A1, expand `templates/sti_template.sv`:

- Name it `sti_<iface>.sv`, module `sti_<iface>`.
- Keep the CPU-slave wrapper (write-decode of `ENA/RATE/MODE/SEED...`, read-decode
  into `cpu_dout`, address self-decode from `STI_ADDR`) **unchanged** — this is what
  makes the driver controllable from the test script via `cpu_write` only.
- Replace only the `GENERATOR BODY` with traffic appropriate to this interface
  (stream/calendar, packet burst, prbs, AXI master, file-replay, ...). Match the
  DUT's handshake (valid/ready, sof/eof) and data width.
- Expose every output the DUT data port needs; expose status counters and any
  captured output as readable registers so testcases can `cpu_read_check` them.
- **Make the driver width-generic — never hardcode the data width.** Parameterise
  by the DUT's data width (`DW`, plus `UW`/`EW` sidebands), derive everything from
  it (`localparam NW = DW/32;`). The payload/capture registers and `din_data` must
  be `[DW-1:0]`. Because the CPU is 32-bit, expose the payload as **word-addressed**
  registers at a base offset (`PT` word `i` at `STI_PT+i`, `i = 0..NW-1`) decoded
  with a range check + variable indexed part-select
  (`pt[(cpu_addr-STI_PT)*32 +: 32]`). A driver hardcoded to one width silently works
  at the default `DW` then fails the first multi-block (`DW=N*128`) testcase.

Additional `sti_*.sv` files can be added later; they are picked up automatically by
the `sti_*.sv` glob in the Makefiles.

## Step A6 - Generate `tb/<ip>/sco_<iface>.sv` per checkable stream output (optional)

Generate a scoreboard only for data-plane outputs that produce a **continuous
stream** (`valid`/`data` beats), where per-beat checking adds value over reading a
final status register. Skip it for IPs whose only outputs are status registers —
those are checked directly with `cpu_read_check`. If no scoreboard is generated,
also drop the `SCO_INSTANCES`/`SCO_DOUT_OR`/`SCO_BASE` hooks from `dut.vh`.

For each such output, expand `templates/sco_template.sv`:

- Name it `sco_<iface>.sv`, module `sco_<iface>`.
- Keep the **CPU-slave wrapper unchanged** (write-decode of `ENA/MODE/CLR` + the
  word-addressed expected payload, read-decode of `ERRCNT/CHKCNT` + first-mismatch
  capture, address self-decode from `SCO_ADDR`). This is what lets the test script
  configure and read the scoreboard via the CPU bus only.
- The scoreboard **taps** the DUT output (`in_valid`/`in_ready`/`in_data`) — it must
  never drive the DUT. Wire the tap in `dut.vh`'s `{{SCO_INSTANCES}}`.
- Replace only the `COMPARE BODY` to match the interface handshake and the
  expected-value source. **Default = OPTION 2:** the expected payload is supplied
  over the CPU bus (written by the testcase, or mirrored from what the matching
  `sti_*` driver injected). **Escape hatch OPTION 1:** build a reference model in the
  body that recomputes expected from observed inputs — use only when the transform is
  non-trivial. **OPTION 3:** replay expected beats from a file.
- On a mismatch the scoreboard prints `[ERROR] ...` then `[FINISH] FAIL` + `$finish`
  (self-fail, consistent with `cpu_read_check`). `ERRCNT` is still exposed so a
  testcase may instead defer the verdict with `cpu_read_check(SCO_ERRCNT, 32'd0)`.
- **Width-generic** like the sti drivers — parameterise by `DATA_W`, word-address the
  expected/capture payload, never hardcode the width.

Additional `sco_*.sv` files are picked up automatically by the `sco_*.sv` glob in the
Makefiles.

---

# Phase B — Plan and Generate the Suite

## Step B1 - Plan the test suite

List all planned testcases across the six mandatory categories:

| Category       | Coverage target |
|----------------|-----------------|
| Reset          | DUT reaches defined idle state after reset; all outputs at documented reset values |
| Basic          | One test per documented feature or operating mode |
| Edge           | Boundary data values (0, all-ones, max-minus-1), empty/full conditions, single-cycle bursts |
| Back-pressure  | Valid/ready handshakes held off; pipeline stalls and drains correctly under sustained back-pressure |
| Error inject   | Out-of-spec stimulus, concurrent events, overflow/underflow conditions |
| Stress         | Back-to-back transactions with no idle cycles; maximum throughput for at least 1000 clock cycles |

Present the full plan as a table before writing any code. Adjust on feedback.

## Step B2 - Write each testcase

For each planned testcase, create `tb/<ip>/tb_<category>_<name>.sv` by expanding
`templates/tb_basic.sv`. File name lowercase, underscores, no spaces, `tb_` prefix
(so the Makefile auto-discovers it).

Each testcase must:

- declare the clock-period params (`T_*`), `RS_LV`, the cpu access latencies
  (`CPU_WR_LAT`, `CPU_RD_LAT`), and clk/rst regs, then `` `include "clock.vh" ``;
- declare the DUT parameters, then `` `include "dut.vh" ``;
- contain a watchdog `initial` that prints `[FINISH] FAIL` on timeout;
- have a single test-script `initial` block that uses **only** the reusable
  sequences from `dut.vh` plus `cpu_write`/`cpu_read`/`cpu_read_check` to: release
  reset, configure the DUT, configure+start the `sti_*` drivers, let traffic run,
  check status/captured output via `cpu_read_check`, and finish with `[FINISH] PASS`.

Keep the testcase thin — sequence calls and the golden check, no bus-level poking
and no direct access to DUT or sti internals.

### Checking and verdict convention

- Status/register outputs are checked with `cpu_read_check` against CPU-readable
  registers. On mismatch it prints `[ERROR] time= ... MISMATCH ...` then
  `[FINISH] FAIL` and `$finish` automatically.
- **Stream outputs are checked by their `sco_*` scoreboard:** the test script loads
  the expected payload and enables the scoreboard with `cpu_write`; the scoreboard
  self-fails on the first mismatched beat. For a deferred verdict, end the run and
  assert `cpu_read_check(SCO_ERRCNT, 32'd0)` instead. Either way the test script
  still touches the bench only through the CPU bus.
- For extra diagnostic context before a manual failure, print an `[ERROR] time= ...`
  line with the relevant signal values, then `[FINISH] FAIL` and `$finish`.
  `vtestrun` harvests `[ERROR]` lines into the issue report.
- A passing testcase ends with `[FINISH] PASS` then `$finish`. This token is the
  single machine-readable verdict (see `.claude/skills/shared/CodingStyle.md`).

For an algorithmic block, also emit a second testcase at a non-default width
(`DW=N*128`, etc.) that reuses the same `dut.vh` sequences — it proves the generated
`sti_*.sv` is genuinely width-generic.

## Step B3 - Self-check each testcase with make

Run from inside `tb/<ip>/`:

```bash
make tb_<category>_<name>
```

This compiles RTL + `sti_*.sv` + the one testcase, elaborates, and simulates under a
timeout. The self-check passes when `sim/tb_<category>_<name>/simulate.log` contains
`[FINISH] PASS`.

| Failure | Action |
|---------|--------|
| compile error (xvlog)    | fix signal name/width/port-map in `dut.vh` or the sti module; rerun |
| elaborate error (xelab)  | add the missing RTL/lib file to `rtl.f`; confirm each `sti_*.sv` compiled; rerun |
| sim timeout              | stimulus never started or DUT stalled — check the `cpu_write` enable sequence / handshake |
| no `[FINISH]` token      | testcase ended without printing the verdict — fix the result block |
| `[FINISH] FAIL` (real)   | for a starter/basic testcase, fix the expected value; if the mismatch is a genuine DUT bug, that is a finding for vtestrun/vdebug — record it and continue |

Maximum 2 rewrite attempts per testcase. If still failing to even produce a clean
`[FINISH]` (compile/elab/timeout) after 2 attempts, record it as `SKIPPED` in
`tc_list.md` and continue. Do not block the suite on one testcase.

## Step B4 - Write the testcase list

After all testcases are written and self-checked, write `tb/<ip>/tc_list.md`:

```markdown
# Testcase List: <ip>

## Bench

Makefile-driven project at `tb/<ip>/`. Run a testcase with `make tb_<name>`;
summarize with `make report`. RTL filelist: `tb/<ip>/script/rtl.f`.

## Testcases

| # | File | Module | Category | Description | Status |
|---|------|--------|----------|-------------|--------|
| 1 | tb_reset_basic.sv | tb_reset_basic | Reset | DUT reaches idle after reset | OK |
| 2 | tb_basic_stream.sv | tb_basic_stream | Basic | Single packet flows end-to-end | OK |
| 3 | tb_edge_empty.sv | tb_edge_empty | Edge | Empty input condition | SKIPPED |
```

Status values: `OK` (self-check produced `[FINISH] PASS`), `SKIPPED` (could not
produce a clean `[FINISH]` after 2 attempts).

## Conventions (must hold)

- **CPU-bus-only:** test scripts touch the bench only through the CPU BFM tasks and
  `dut.vh` sequences. No direct poking of DUT or sti internals from `tb_*.sv`.
- **Verdict:** print `[FINISH] PASS` / `[FINISH] FAIL` then `$finish`; `cpu_read_check`
  auto-fails on mismatch; no token ⇒ FAIL.
- **Width-generic** `sti_*.sv`, `sco_*.sv`, and `dut.vh` sequences — never hardcode the data width.
- **Scoreboards are CPU-slave observers:** a `sco_*.sv` taps a DUT output and never drives it; it is configured/read over the CPU bus like any other slave.
- **Reusable sequences live in `dut.vh`**, not in testcases.
- Testbench is SystemVerilog under `tb/`; RTL stays Verilog-2005.

## Known Issues and Fixes

<!-- Append issues found while running this skill. Format:
### [Tool] - <short title>
**Symptom:** ...
**Cause:** ...
**Fix:** ...
-->
